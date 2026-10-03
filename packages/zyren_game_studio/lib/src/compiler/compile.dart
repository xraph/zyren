part of '../../compiler.dart';

enum GameBuildStatus { ready, failed, cancelled }

final class GameBuildResult {
  final GameBuildStatus status;
  final List<String> diagnostics;
  final GameExportManifest? artifact;
  final PipelineBuildResult? pipelineResult;
  GameBuildResult._(
    this.status,
    List<String> diagnostics,
    this.artifact,
    this.pipelineResult,
  ) : diagnostics = List.unmodifiable(diagnostics);
}

/// Uses Pipeline jobs, transforms, byte limits and host-authorized pinned assets.
final class GameProjectCompiler {
  static const version = '2';
  final GameRegistry registry;
  final PipelineAssetLibrary assets;
  final StudioExtensionRegistry extensions;
  final PipelineCache cache;
  final PipelineLimits limits;
  GameProjectCompiler({
    required GameRegistry registry,
    required this.assets,
    StudioExtensionRegistry? extensions,
    PipelineCache? cache,
    this.limits = const PipelineLimits(),
  }) : registry = registry.snapshot(),
       extensions =
           extensions ??
           (StudioExtensionRegistry()..register(GameDocumentCodec(registry))),
       cache = cache ?? PipelineCache();

  PipelineBuildRecipe recipe({
    required String id,
    required List<StudioDocument> documents,
    required String startupLevel,
    required GameBuildProfile profile,
    Map<String, PipelineAssetReference> models = const {},
    PipelineBuildResult? previous,
  }) {
    final sources = List<StudioDocument>.unmodifiable(documents);
    final pins = Map<String, PipelineAssetReference>.unmodifiable(models);
    return PipelineBuildRecipe(
      id: id,
      version: version,
      run: (token) =>
          _build(sources, startupLevel, profile, pins, previous, token),
    );
  }

  Future<GameBuildResult> compile({
    required List<StudioDocument> documents,
    required String startupLevel,
    required GameBuildProfile profile,
    Map<String, PipelineAssetReference> models = const {},
    PipelineBuildResult? previous,
    LoadCancellation? cancellation,
    Future<void> Function(PipelineBundle, LoadCancellation)? publish,
  }) async {
    final runtime = PipelineBuildRuntime(
      cache: cache,
      publish: publish,
      recipes: [
        recipe(
          id: 'game.compile',
          documents: documents,
          startupLevel: startupLevel,
          profile: profile,
          models: models,
          previous: previous,
        ),
      ],
    );
    final job = runtime.start('game.compile');
    final registration = cancellation?.onCancel(() => runtime.cancel(job.id));
    try {
      await job.done;
      switch (job.state) {
        case PipelineBuildState.succeeded:
          final result = job.result!;
          final compiled = CompiledGameProject.decode(
            utf8.decode(result.bundle.resource('game.recipe').bytes),
            registry,
          );
          return GameBuildResult._(
            GameBuildStatus.ready,
            [],
            GameExportManifest(bundle: result.bundle, project: compiled),
            result,
          );
        case PipelineBuildState.cancelled:
          return GameBuildResult._(
            GameBuildStatus.cancelled,
            ['cancelled'],
            null,
            null,
          );
        case PipelineBuildState.failed:
          return GameBuildResult._(
            GameBuildStatus.failed,
            [job.errorCode ?? 'build-failed'],
            null,
            null,
          );
        case PipelineBuildState.running:
          throw StateError('Build completion is inconsistent.');
      }
    } catch (error) {
      return GameBuildResult._(
        GameBuildStatus.failed,
        [error.toString().substring(0, error.toString().length.clamp(0, 2048))],
        null,
        null,
      );
    } finally {
      registration?.dispose();
      await runtime.close();
    }
  }

  Future<PipelineBuildResult> _build(
    List<StudioDocument> documents,
    String startupLevel,
    GameBuildProfile profile,
    Map<String, PipelineAssetReference> models,
    PipelineBuildResult? previous,
    LoadCancellation token,
  ) async {
    token.throwIfCancelled();
    if (documents.isEmpty ||
        documents.length > registry.limits.maxLevels ||
        models.length > 256) {
      throw FormatException('Compiler input budget exceeded.');
    }
    final codec = GameDocumentCodec(registry);
    final data = <GameDocumentData>[];
    final prepared = <String, (PipelineSource, ResolvedSource)>{};
    var totalBytes = 0;
    void add(PipelineSource source, ResolvedSource resolved) {
      final old = prepared[source.sourceId];
      if (old != null &&
          (old.$1.uri != source.uri ||
              old.$1.revision != source.revision ||
              sha256.convert(old.$2.bytes).toString() !=
                  sha256.convert(resolved.bytes).toString())) {
        throw FormatException('Conflicting compiler source identity.');
      }
      if (old == null) {
        if (prepared.length + 3 > limits.maxSources ||
            resolved.bytes.length > limits.maxSourceBytes ||
            totalBytes + resolved.bytes.length > limits.maxTotalBytes) {
          throw FormatException('Compiler source budget exceeded.');
        }
        totalBytes += resolved.bytes.length;
      }
      prepared[source.sourceId] = (source, resolved);
    }

    Future<void> resolve(PipelineAssetReference reference) async {
      if (await assets.inspect(reference, cancellation: token) !=
          PipelineAssetStatus.available) {
        throw StateError('Pinned compiler asset unavailable.');
      }
      final bundle = await assets.readBundle(reference.bundleVersion, token);
      token.throwIfCancelled();
      if (bundle == null || bundle.version != reference.bundleVersion) {
        throw StateError('Asset bundle pin changed.');
      }
      final target = bundle.resource(reference.sourceId);
      if (target.digest != reference.sha256 ||
          target.source.revision != reference.sourceRevision ||
          target.source.uri != reference.uri) {
        throw StateError('Asset resource pin changed.');
      }
      for (final resource in bundle.resources) {
        add(
          resource.source,
          ResolvedSource(
            effectiveUri: resource.effectiveUri,
            bytes: resource.bytes,
            mediaType: resource.mediaType,
          ),
        );
      }
    }

    for (final document in documents) {
      extensions.validateDocument(document, requireSupported: true);
      final record = document.extensions[codec.namespace];
      if (record == null) throw FormatException('Game extension is missing.');
      data.add(codec.expand(document));
      final bytes = Uint8List.fromList(utf8.encode(document.encode()));
      final uri = Uri.parse(
        'game:///document/${Uri.encodeComponent(document.id)}',
      );
      add(
        PipelineSource(
          sourceId: 'document.${document.id}',
          revision: sha256.convert(bytes).toString(),
          uri: uri,
        ),
        ResolvedSource(
          effectiveUri: uri,
          bytes: bytes,
          mediaType: 'application/json',
        ),
      );
      for (final asset in document.assets) {
        if (asset.provider != 'zyren.pipeline') {
          throw StateError('Unsupported game asset provider.');
        }
        await resolve(PipelineAssetReference.fromJson(asset.reference));
      }
    }
    for (final pin in models.values) {
      await resolve(pin);
    }
    if (data.map((d) => d.projectId).toSet().length != 1) {
      throw FormatException('Documents belong to different game projects.');
    }
    final sources = prepared.values.map((v) => v.$1).toList();
    final documentIds = sources.map((s) => s.sourceId).toList();
    final transform = PipelineTransform(
      sourceId: 'game.recipe',
      uri: Uri.parse('game:///compiled/recipe.json'),
      tool: 'zyren.game-compiler',
      toolVersion: version,
      inputs: documentIds,
      options: {
        'profile': profile.toJson(),
        'startupLevel': startupLevel,
        'componentVersions': CompiledGameProject(
          project: GameProject(
            id: data.first.projectId,
            startupLevel: startupLevel,
            levels: [
              for (var i = 0; i < data.length; i++)
                GameLevel(
                  id: data[i].levelId,
                  scene: GameSceneIdentity(
                    documents[i].id,
                    sources
                        .firstWhere(
                          (s) => s.sourceId == 'document.${documents[i].id}',
                        )
                        .revision,
                  ),
                  entities: data[i].entities,
                ),
            ],
            registry: registry,
          ),
        ).componentVersions,
        'models': models.map((k, v) => MapEntry(k, v.toJson())),
      },
      mediaType: 'application/vnd.zyren.game+json',
      run: (context) async {
        context.cancellation.throwIfCancelled();
        final assetRefs = context.inputs.values
            .where(
              (r) => !documents.any(
                (d) => r.source.sourceId == 'document.${d.id}',
              ),
            )
            .map(
              (r) => GameAssetReference(
                id: r.source.sourceId,
                revision: r.source.revision,
                uri: r.source.uri,
                digest: r.digest,
              ),
            )
            .toList();
        final project = GameProject(
          id: data.first.projectId,
          startupLevel: startupLevel,
          registry: registry,
          capabilityRequirements: profile.capabilities,
          modelReferences: models.map((k, v) => MapEntry(k, v.toJson())),
          levels: [
            for (var i = 0; i < data.length; i++)
              GameLevel(
                id: data[i].levelId,
                scene: GameSceneIdentity(
                  documents[i].id,
                  context.inputs['document.${documents[i].id}']!.digest,
                ),
                entities: data[i].entities,
              ),
          ],
        );
        final compiled = CompiledGameProject(
          project: project,
          fixedHz: profile.fixedHz,
          compilerVersion: version,
          assets: assetRefs,
          artifactHashes: {for (final ref in assetRefs) ref.id: ref.digest},
          sceneNodes: {
            for (var i = 0; i < data.length; i++)
              data[i].levelId: documents[i].expandedNodes.values
                  .map((n) => _runtimeNode(n, documents[i]))
                  .toList(),
          },
        );
        return Uint8List.fromList(utf8.encode(compiled.encode()));
      },
    );
    return PipelineIncrementalBuilder(
      PipelineBuilder(
        resolver: _CompilerSources({
          for (final value in prepared.values) value.$1.uri: value.$2,
        }),
        limits: limits,
      ),
    ).build(
      sources: sources,
      transforms: [transform],
      entrySourceId: 'game.recipe',
      previous: previous,
      cancellation: token,
    );
  }
}

Map<String, Object?> _runtimeNode(StudioNode node, StudioDocument document) {
  final recipe = node.toJson();
  if (node.assetId != null) {
    final asset = document.assets.singleWhere(
      (asset) => asset.id == node.assetId,
    );
    final pin = PipelineAssetReference.fromJson(asset.reference);
    recipe['assetReference'] = GameAssetReference(
      id: pin.sourceId,
      revision: pin.sourceRevision,
      uri: pin.uri,
      digest: pin.sha256,
    ).toJson();
  }
  return recipe;
}

final class _CompilerSources implements ByteSourceResolver {
  final Map<Uri, ResolvedSource> sources;
  _CompilerSources(this.sources);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final result = sources[uri];
    if (result == null) throw StateError('Compiler source missing.');
    return result;
  }
}
