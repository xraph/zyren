import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pipeline/preparation.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'preparation_fixture.dart';

Future<void> main() async {
  final worker = PipelinePreparer(
    executable: File(
      'packages/zyren_pipeline/native/target/debug/zyren_pipeline_prepare',
    ).absolute.path,
  );
  final original = grid().capture();
  Map<String, Object?> describe(List<int> indices) => {
    'positions': original.positions,
    'normals': original.normals,
    'uv': original.uv0,
    'indices': indices,
    'sourceId': 'part:grid',
  };
  Uint8List encode(Object value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
  final files = {
    Uri.parse('pipeline:///original.json'): encode(describe(original.indices)),
    Uri.parse('pipeline:///original.rgba'): checkerPixels(),
  };
  final result =
      await PipelineIncrementalBuilder(
        PipelineBuilder(resolver: _Sources(files)),
      ).build(
        sources: [
          for (final entry in files.entries)
            PipelineSource(
              sourceId: entry.key.path.endsWith('json')
                  ? 'original-mesh'
                  : 'original-texture',
              revision: 'fixture-1',
              uri: entry.key,
            ),
        ],
        transforms: [
          PipelineTransform(
            sourceId: 'mesh-lod',
            uri: Uri.parse('pipeline:///lod.json'),
            tool: 'meshopt',
            toolVersion: pipelinePreparationVersion,
            inputs: ['original-mesh'],
            options: {'ratio': .25, 'maxError': .001},
            run: (context) async {
              final mesh = await worker.mesh(
                geometry: original,
                sourceId: 'part:grid',
                ratio: .25,
                maxError: .001,
                cancellation: context.cancellation,
              );
              return encode({
                ...describe(mesh.geometry.indices),
                'error': mesh.absoluteError,
                'inputIndexBytes': mesh.inputIndexBytes,
                'outputIndexBytes': mesh.outputIndexBytes,
              });
            },
          ),
          PipelineTransform(
            sourceId: 'texture',
            uri: Uri.parse('pipeline:///color.ktx2'),
            tool: 'basis',
            toolVersion: pipelinePreparationVersion,
            inputs: ['original-texture'],
            options: {
              'profile': 'uastc',
              'srgb': true,
              'mipmaps': true,
              'quality': 75,
              'effort': 2,
            },
            run: (context) async => (await worker.texture(
              rgba: context.inputs['original-texture']!.bytes,
              width: 16,
              height: 16,
              srgb: true,
              decoder: const NativeTextureDecoder(),
              cancellation: context.cancellation,
            )).ktx2,
          ),
        ],
        entrySourceId: 'mesh-lod',
      );
  final output = File(
    'packages/zyren_pipeline/example/native_app/assets/fixture.zybundle',
  );
  await output.parent.create(recursive: true);
  await output.writeAsBytes(result.bundle.encode());
  print(
    'Prepared ${result.bundle.version}: ${result.bundle.byteLength} payload bytes',
  );
}

final class _Sources implements ByteSourceResolver {
  final Map<Uri, Uint8List> files;
  _Sources(this.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: files[uri]!);
}
