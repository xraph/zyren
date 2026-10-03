part of '../../compiler.dart';

/// The game recipe stays inside Pipeline's integrity-checked resource container.
final class GameExportManifest {
  final PipelineBundle bundle;
  final CompiledGameProject project;
  GameExportManifest({required this.bundle, required this.project}) {
    if (utf8.decode(bundle.resource('game.recipe').bytes) != project.encode()) {
      throw StateError('Recipe differs from bundled artifact.');
    }
  }
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'bundleVersion': bundle.version,
    'buildId': project.buildId,
    'compilerVersion': project.compilerVersion,
    'recipe': PipelineAssetReference.fromBundle(
      bundle,
      sourceId: 'game.recipe',
    ).toJson(),
    'capabilities': project.capabilityRequirements,
    'models': project.project.modelReferences,
    'assets': project.assets.map((a) => a.toJson()).toList(),
  };
  factory GameExportManifest.decodeBundle(
    Uint8List bytes,
    GameRegistry registry,
  ) {
    final bundle = PipelineBundle.decode(bytes);
    return GameExportManifest(
      bundle: bundle,
      project: CompiledGameProject.decode(
        utf8.decode(bundle.resource('game.recipe').bytes),
        registry,
      ),
    );
  }

  /// Resolves saved pins without requesting another bundle or network source.
  GameAssetResolver offlineResolver() => _GameBundleAssets(bundle);
}

final class _BundleLease implements GameAssetLease {
  final Uint8List _bytes;
  bool _closed = false;
  _BundleLease(Uint8List bytes) : _bytes = Uint8List.fromList(bytes);
  @override
  Uint8List get bytes {
    if (_closed) throw StateError('Asset lease is closed.');
    return Uint8List.fromList(_bytes);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

final class _GameBundleAssets implements GameAssetResolver {
  final PipelineBundle bundle;
  _GameBundleAssets(this.bundle);
  @override
  Future<GameAssetLease> load(
    GameAssetReference reference,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final resource = bundle.resource(reference.id);
    if (resource.source.revision != reference.revision ||
        resource.source.uri != reference.uri ||
        resource.digest != reference.digest) {
      throw StateError('Runtime asset pin differs.');
    }
    return _BundleLease(resource.bytes);
  }
}
