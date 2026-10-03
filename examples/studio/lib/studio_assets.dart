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
          label: 'glTF binary or Zyren bundle',
          extensions: ['glb', 'zyrenbundle', 'bundle'],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return null;
    cancellation.throwIfCancelled();
    if (await file.length() > const PipelineLimits().maxArchiveBytes) {
      throw StateError('Import exceeds the bundle size limit.');
    }
    final bytes = await file.readAsBytes();
    cancellation.throwIfCancelled();
    return importBytes(
      bytes,
      file.name,
      id: id,
      replacing: replacing,
      mapSources: mapSources,
      cancellation: cancellation,
    );
  }

  Future<StudioAsset> importBytes(
    Uint8List bytes,
    String filename, {
    required String id,
    StudioAsset? replacing,
    StudioSourceMapping? mapSources,
    required LoadCancellation cancellation,
  }) async {
    final PipelineBundle bundle;
    if (filename.toLowerCase().endsWith('.glb')) {
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
