import 'studio_model_import.dart';
import 'package:zyren_studio/streaming.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_studio/zyren_studio.dart';

typedef StudioSourceMapping =
    Future<Map<String, int>?> Function(
      Map<int, String> nodes,
      Map<String, int> previous,
    );

/// Native host adapter. The document keeps Pipeline's exact descriptor unchanged.
final class StudioPipelineAssets implements StudioAssetResolver {
  final FilePipelineCache cache;
  late final library = PipelineAssetLibrary(
    services: SceneRuntime.defaultAssetServices,
    readBundle: (version, cancellation) =>
        cache.get(version, cancellation: cancellation),
  );
  StudioPipelineAssets(Directory directory)
    : cache = FilePipelineCache(directory: directory);

  @override
  Future<StudioAssetTemplate> load(
    StudioAsset asset,
    LoadCancellation cancellation,
  ) async {
    if (asset.provider != 'zyren.pipeline') {
      throw StateError('Unsupported asset provider ${asset.provider}.');
    }
    final loaded = await library.loadGltf(
      PipelineAssetReference.fromJson(asset.reference),
      cancellation: cancellation,
    );
    return _Template(asset, loaded);
  }

  Future<Map<String, Uint8List>> packageResources(
    StudioDocument document,
  ) async {
    final result = <String, Uint8List>{};
    for (final asset in document.assets) {
      if (asset.provider != 'zyren.pipeline') {
        throw StateError('No export adapter for ${asset.provider}.');
      }
      final pin = PipelineAssetReference.fromJson(
        asset.reference,
      ).bundleVersion;
      final bundle = await cache.get(pin);
      if (bundle == null) {
        throw StateError('Missing pinned asset ${asset.label}.');
      }
      result[pin] = bundle.encode();
    }
    return result;
  }

  Future<void> importPackage(ZyrenSceneStream stream) async {
    for (final pin
        in (stream.manifest['resources'] as Map).keys.cast<String>()) {
      final bundle = PipelineBundle.decode(await stream.readResource(pin));
      if (bundle.version != pin) {
        throw const FormatException('Asset version differs from scene pin.');
      }
      if (!await cache.put(bundle, pin: true)) {
        throw StateError('Asset cache is full.');
      }
    }
  }

  Future<void> retainPins(Iterable<StudioDocument> documents) async {
    final versions = {
      for (final doc in documents)
        for (final asset in doc.assets)
          if (asset.provider == 'zyren.pipeline')
            PipelineAssetReference.fromJson(asset.reference).bundleVersion,
    };
    for (final entry in await cache.inspect()) {
      final keep = versions.contains(entry.version);
      if (entry.pinned != keep) await cache.setPinned(entry.version, keep);
    }
  }

  Future<PipelineAssetStatus> inspect(StudioAsset asset) =>
      library.inspect(PipelineAssetReference.fromJson(asset.reference));

  Future<StudioAsset?> choose({
    required String id,
    StudioAsset? replacing,
    StudioSourceMapping? mapSources,
    required LoadCancellation cancellation,
  }) async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '3D models and Zyren bundles',
          extensions: studioModelExtensions,
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return null;
    return importFile(
      File(file.path),
      id: id,
      replacing: replacing,
      mapSources: mapSources,
      cancellation: cancellation,
    );
  }

  Future<StudioAsset> importFile(
    File file, {
    required String id,
    StudioAsset? replacing,
    StudioSourceMapping? mapSources,
    required LoadCancellation cancellation,
    bool requestFolderAccess = true,
    String? blenderExecutable,
  }) async {
    if (requestFolderAccess &&
        Platform.isMacOS &&
        await studioModelNeedsFolderAccess(file, cancellation)) {
      final parent = await file.parent.resolveSymbolicLinks();
      final selected = await getDirectoryPath(
        initialDirectory: parent,
        confirmButtonText: 'Use model folder',
      );
      if (selected == null) throw LoadCancelled();
      if (await Directory(selected).resolveSymbolicLinks() != parent) {
        throw StateError(
          'Choose the folder containing the model and its textures.',
        );
      }
    }
    cancellation.throwIfCancelled();
    final bundle = await prepareStudioModel(
      file,
      id: id,
      cancellation: cancellation,
      blenderExecutable: blenderExecutable,
    );
    return importBytes(
      Uint8List(0),
      file.uri.pathSegments.last,
      id: id,
      replacing: replacing,
      mapSources: mapSources,
      cancellation: cancellation,
      prepared: bundle,
    );
  }

  Future<StudioAsset> importBytes(
    Uint8List bytes,
    String filename, {
    required String id,
    StudioAsset? replacing,
    StudioSourceMapping? mapSources,
    required LoadCancellation cancellation,
    PipelineBundle? prepared,
  }) async {
    final PipelineBundle bundle;
    if (prepared != null) {
      bundle = prepared;
    } else if (filename.toLowerCase().endsWith('.glb')) {
      final prior = replacing == null
          ? null
          : PipelineAssetReference.fromJson(replacing.reference);
      final uri = prior?.uri ?? Uri(scheme: 'asset', path: '/studio/$id.glb');
      bundle = await PipelineBuilder(resolver: _Bytes(bytes)).build(
        entrySourceId: prior?.sourceId ?? id,
        sources: [
          PipelineSource(
            sourceId: prior?.sourceId ?? id,
            revision: DateTime.now().microsecondsSinceEpoch.toString(),
            uri: uri,
          ),
        ],
        cancellation: cancellation,
      );
    } else {
      bundle = PipelineBundle.decode(bytes);
    }
    // Decode before pinning. Invalid glTF never becomes an active editor asset.
    final temporary = PipelineAssetLibrary(
      services: SceneRuntime.defaultAssetServices,
      readBundle: (_, _) async => bundle,
    );
    final reference = PipelineAssetReference.fromBundle(bundle);
    final loaded = await temporary.loadGltf(
      reference,
      cancellation: cancellation,
    );
    var sources = replacing?.sourceNodes ?? <String, int>{};
    try {
      // Node indices are tied to an exact pin. Reimport requires an explicit new
      // source map for imported subobject bindings; root instance IDs remain stable.
      if (replacing != null &&
          replacing.sourceNodes.isNotEmpty &&
          mapSources == null &&
          reference.bundleVersion != replacing.reference['bundleVersion']) {
        throw StateError(
          'This asset has source-node bindings. Supply an updated source map before reimporting it.',
        );
      }
      final model = loaded.instantiate();
      if (mapSources != null) {
        final result = await mapSources({
          for (final node in model.nodes.entries)
            node.key: node.value.name ?? '',
        }, sources);
        if (result == null) throw LoadCancelled();
        sources = result;
      }
      if (sources.values.any((index) => !model.nodes.containsKey(index))) {
        throw StateError('A source mapping refers to an absent model node.');
      }
      StudioAsset(
        id: id,
        label: filename,
        provider: 'zyren.pipeline',
        reference: reference.toJson(),
        sourceNodes: sources,
      );
      cancellation.throwIfCancelled();
      if (!await cache.put(bundle, pin: true, cancellation: cancellation)) {
        throw StateError('The pinned asset cache is full.');
      }
    } finally {
      await loaded.close();
    }
    return StudioAsset(
      id: id,
      label: filename,
      provider: 'zyren.pipeline',
      reference: reference.toJson(),
      sourceNodes: sources,
    );
  }
}

final class _Template implements StudioAssetTemplate {
  final StudioAsset asset;
  final PipelineLoadedAsset loaded;
  _Template(this.asset, this.loaded);
  @override
  StudioAssetInstance instantiate() {
    final model = loaded.instantiate();
    final sources = <String, Object3D>{};
    for (final entry in asset.sourceNodes.entries) {
      final node = model.nodes[entry.value];
      if (node == null) {
        throw StateError(
          'Saved source node ${entry.key} is absent from the pinned model.',
        );
      }
      sources[entry.key] = node;
    }
    return StudioAssetInstance(model, sources: sources);
  }

  @override
  Future<void> close() => loaded.close();
}

final class _Bytes implements ByteSourceResolver {
  final Uint8List bytes;
  _Bytes(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    if (bytes.length > context.maxBytes) {
      throw StateError('Source exceeds its byte budget.');
    }
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}
