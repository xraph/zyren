import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'zyren_pipeline.dart';

/// Persists the shared Studio schema in a dedicated versioned document bundle.
/// The host supplies durable storage and atomic compare-and-write semantics.
/// Credentials, location and authorization remain with that host.
final class PipelineStudioStore implements StudioStore {
  final String documentId, sourceId;
  final Uri uri;
  final Future<PipelineBundle?> Function() readBundle;
  final Future<bool> Function(String? expectedVersion, PipelineBundle next)
  compareAndWrite;
  String? _base;
  bool _read = false, _busy = false;
  PipelineStudioStore({
    required this.documentId,
    required this.sourceId,
    required this.uri,
    required this.readBundle,
    required this.compareAndWrite,
  }) {
    PipelineSource(sourceId: sourceId, revision: 'document', uri: uri);
  }
  @override
  Future<StudioDocument?> read() async {
    if (_busy) throw StateError('Studio bundle storage is busy.');
    _busy = true;
    try {
      final bundle = await readBundle();
      StudioDocument? document;
      if (bundle != null) {
        document = StudioDocument.decode(
          utf8.decode(bundle.resource(sourceId).bytes),
        );
        if (document.id != documentId) {
          throw const FormatException('Studio document identity differs.');
        }
      }
      _base = bundle?.version;
      _read = true;
      return document;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> write(StudioDocument document) async {
    if (_busy || !_read) {
      throw StateError('Read the Studio store before writing.');
    }
    if (document.id != documentId) {
      throw ArgumentError('Studio document identity differs.');
    }
    _busy = true;
    try {
      final bytes = Uint8List.fromList(utf8.encode(document.encode()));
      final bundle =
          await PipelineBuilder(resolver: _DocumentSource(uri, bytes)).build(
            entrySourceId: sourceId,
            sources: [
              PipelineSource(
                sourceId: sourceId,
                revision: sha256.convert(bytes).toString(),
                uri: uri,
              ),
            ],
          );
      if (!await compareAndWrite(_base, bundle)) {
        throw StateError('Studio bundle changed. Reload before saving.');
      }
      _base = bundle.version;
    } finally {
      _busy = false;
    }
  }
}

final class _DocumentSource implements ByteSourceResolver {
  final Uri uri;
  final Uint8List bytes;
  _DocumentSource(this.uri, this.bytes);
  @override
  Future<ResolvedSource> read(Uri requested, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    if (requested != uri) throw const FormatException('Unknown Studio source.');
    return ResolvedSource(
      effectiveUri: uri,
      bytes: bytes,
      mediaType: 'application/json',
    );
  }
}

/// Shared resolver for Studio and Flutter applications loading pinned bundles.
final class PipelineStudioAssetResolver implements StudioAssetResolver {
  final PipelineAssetLibrary library;
  PipelineStudioAssetResolver(this.library);
  @override
  Future<StudioAssetTemplate> load(
    StudioAsset asset,
    LoadCancellation cancellation,
  ) async {
    if (asset.provider != 'zyren.pipeline') {
      throw StateError('Unsupported asset provider ${asset.provider}.');
    }
    return _StudioTemplate(
      asset,
      await library.loadGltf(
        PipelineAssetReference.fromJson(asset.reference),
        cancellation: cancellation,
      ),
    );
  }
}

final class _StudioTemplate implements StudioAssetTemplate {
  final StudioAsset asset;
  final PipelineLoadedAsset loaded;
  _StudioTemplate(this.asset, this.loaded);
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
