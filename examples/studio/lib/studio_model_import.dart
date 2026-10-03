import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

const studioModelExtensions = [
  'glb',
  'gltf',
  'fbx',
  'obj',
  'zyrenbundle',
  'bundle',
];

Future<Uint8List> _read(
  File file,
  LoadCancellation cancellation,
  int limit,
) async {
  if (await file.length() > limit) {
    throw StateError('Model exceeds the import size limit.');
  }
  final result = BytesBuilder();
  await for (final bytes in file.openRead()) {
    cancellation.throwIfCancelled();
    if (result.length + bytes.length > limit) {
      throw StateError('Model exceeds the import size limit.');
    }
    result.add(bytes);
  }
  cancellation.throwIfCancelled();
  return result.takeBytes();
}

/// Self-contained GLB files need no directory grant on macOS.
Future<bool> studioModelNeedsFolderAccess(
  File file,
  LoadCancellation cancellation,
) async {
  final extension = file.path.split('.').last.toLowerCase();
  if (['gltf', 'fbx', 'obj'].contains(extension)) return true;
  if (extension != 'glb') return false;
  final bytes = await _read(
    file,
    cancellation,
    const PipelineLimits().maxSourceBytes,
  );
  final root = jsonDecode(utf8.decode(_glbJson(bytes))) as Map<String, dynamic>;
  return _references(root).any((uri) => !uri.startsWith('data:'));
}

Iterable<String> _references(Map<String, dynamic> root) => {
  for (final group in ['buffers', 'images'])
    for (final entry in root[group] as List? ?? const [])
      if (entry['uri'] is String) entry['uri'] as String,
};

/// Packages local glTF dependencies and converted models into the same pinned cache.
Future<PipelineBundle> prepareStudioModel(
  File file, {
  required String id,
  required LoadCancellation cancellation,
  String? blenderExecutable,
}) async {
  final extension = file.path.split('.').last.toLowerCase();
  if (!studioModelExtensions.contains(extension)) {
    throw UnsupportedError('Choose GLB, glTF, FBX, OBJ or a Zyren bundle.');
  }
  final original = await _read(
    file,
    cancellation,
    (extension == 'bundle' || extension == 'zyrenbundle')
        ? const PipelineLimits().maxArchiveBytes
        : const PipelineLimits().maxSourceBytes,
  );
  if (extension == 'bundle' || extension == 'zyrenbundle') {
    return PipelineBundle.decode(original);
  }
  final virtual = Uri(
    scheme: 'asset',
    path: '/studio/$id/model.${extension == 'gltf' ? 'gltf' : 'glb'}',
  );
  final data = <Uri, Uint8List>{};
  final converted = extension == 'fbx' || extension == 'obj';
  if (converted) {
    data[virtual] = await _convert(file, cancellation, blenderExecutable);
    data[virtual.resolve('source.$extension')] = original;
  } else {
    data[virtual] = original;
    final jsonBytes = extension == 'gltf' ? original : _glbJson(original);
    final root = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    final references = _references(root);
    final directory = await file.parent.resolveSymbolicLinks();
    var total = original.length;
    for (final reference in references) {
      cancellation.throwIfCancelled();
      final uri = Uri.parse(reference);
      if (uri.scheme == 'data') continue;
      if (uri.hasScheme ||
          uri.hasAuthority ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.startsWith('/') ||
          uri.pathSegments.any((s) => s == '..' || s.contains('\\'))) {
        throw const FormatException(
          'Model dependencies must be inside the selected model folder.',
        );
      }
      if (data.length >= const PipelineLimits().maxSources) {
        throw StateError('Too many model dependencies.');
      }
      final dependency = File.fromUri(file.parent.uri.resolveUri(uri));
      final resolved = await dependency.resolveSymbolicLinks();
      if (!resolved.startsWith('$directory${Platform.pathSeparator}')) {
        throw const FormatException('Model dependency leaves its folder.');
      }
      final bytes = await _read(
        File(resolved),
        cancellation,
        const PipelineLimits().maxSourceBytes,
      );
      total += bytes.length;
      if (total > const PipelineLimits().maxTotalBytes) {
        throw StateError('Model dependencies exceed the import size limit.');
      }
      data[virtual.resolveUri(uri)] = bytes;
    }
  }
  final revision = DateTime.now().microsecondsSinceEpoch.toString();
  return PipelineBuilder(resolver: _ModelSources(data)).build(
    entrySourceId: id,
    processing: converted
        ? PipelineProcessing.derived
        : PipelineProcessing.original,
    sources: [
      for (final entry in data.entries.toList().asMap().entries)
        PipelineSource(
          sourceId: entry.key == 0 ? id : '$id-dependency-${entry.key}',
          revision: revision,
          uri: entry.value.key,
        ),
    ],
    cancellation: cancellation,
  );
}

Uint8List _glbJson(Uint8List bytes) {
  if (bytes.length < 20) throw const FormatException('Invalid GLB header.');
  final header = ByteData.sublistView(bytes);
  final length = header.getUint32(12, Endian.little);
  if (header.getUint32(0, Endian.little) != 0x46546c67 ||
      header.getUint32(16, Endian.little) != 0x4e4f534a ||
      20 + length > bytes.length) {
    throw const FormatException('Invalid GLB JSON chunk.');
  }
  return Uint8List.sublistView(bytes, 20, 20 + length);
}

Future<Uint8List> _convert(
  File file,
  LoadCancellation cancellation,
  String? executable,
) async {
  final blender =
      executable ??
      (Platform.isMacOS
          ? '/Applications/Blender.app/Contents/MacOS/Blender'
          : 'blender');
  final temporary = await Directory.systemTemp.createTemp(
    'studio-model-convert-',
  );
  Process? process;
  Registration? registration;
  try {
    final output = File('${temporary.path}/model.glb');
    try {
      process = await Process.start(blender, [
        '--background',
        '--factory-startup',
        '--disable-autoexec',
        '--python-exit-code',
        '1',
        '--python-expr',
        _conversionScript,
        '--',
        file.absolute.path,
        output.path,
      ]);
    } on ProcessException {
      throw StateError(
        'FBX and OBJ import require Blender. Install Blender in Applications (macOS) or on PATH, then retry.',
      );
    }
    final running = process;
    registration = cancellation.onCancel(
      () => running.kill(ProcessSignal.sigkill),
    );
    final log = StringBuffer();
    Future<void> drain(Stream<List<int>> stream) async {
      await for (final chunk in stream.transform(utf8.decoder)) {
        if (log.length < 8192) {
          log.write(
            chunk.substring(0, chunk.length.clamp(0, 8192 - log.length)),
          );
        }
      }
    }

    final logs = Future.wait([drain(process.stdout), drain(process.stderr)]);
    final code = await process.exitCode.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        running.kill(ProcessSignal.sigkill);
        throw TimeoutException('Model conversion exceeded two minutes.');
      },
    );
    await logs;
    cancellation.throwIfCancelled();
    if (code != 0 || !await output.exists()) {
      throw StateError(
        'Model conversion failed. Check the file and its textures. ${log.toString().split('\n').where((line) => line.contains('Error')).lastOrNull ?? 'Blender exited with code $code.'}',
      );
    }
    return await _read(
      output,
      cancellation,
      const PipelineLimits().maxSourceBytes,
    );
  } finally {
    registration?.dispose();
    process?.kill(ProcessSignal.sigkill);
    if (process != null) await process.exitCode;
    await temporary.delete(recursive: true);
  }
}

const _conversionScript = r"""
import bpy, sys, os
source, output = sys.argv[sys.argv.index('--') + 1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
# Conversion needs no render-engine add-ons or their version-specific properties.
if 'cycles' in bpy.context.preferences.addons:
    bpy.ops.preferences.addon_disable(module='cycles')
if source.lower().endswith('.fbx'):
    bpy.ops.import_scene.fbx(filepath=source, use_image_search=False)
else:
    bpy.ops.wm.obj_import(filepath=source)
if not any(o.type == 'MESH' for o in bpy.context.scene.objects):
    raise ValueError('No mesh objects were found')
for image in bpy.data.images:
    if image.source == 'FILE' and not image.packed_file and not os.path.isfile(bpy.path.abspath(image.filepath)):
        raise ValueError('Missing texture: ' + image.name)
bpy.ops.export_scene.gltf(filepath=output, export_format='GLB', export_animations=True, export_skins=True, export_morph=True)
""";

final class _ModelSources implements ByteSourceResolver {
  final Map<Uri, Uint8List> data;
  _ModelSources(this.data);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final bytes = data[uri];
    if (bytes == null || bytes.length > context.maxBytes) {
      throw StateError('Model source unavailable or too large.');
    }
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}
