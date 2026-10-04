import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_studio/ai.dart';
import 'package:zyren_game_studio/gameplay.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_native/runtime.dart' show GameRuntimeResourceLease;
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'studio_assets.dart';

/// Editor tools and asset preparation belong to this owner. Play owns its AI lease.
final class StudioGameWorkspace {
  final GameRuleLibrary rules = GameRuleLibrary();
  late final authoring = createGameAiDevelopmentAuthoring(rules: rules);
  final GameAiWorkspace ai = GameAiWorkspace(maxActors: 256);
  final _artifacts = <String, ModelArtifact>{};
  final _preparing = <String, ModelArtifact>{};
  final _launchManifests = <String, MlModelManifest>{};
  MlModelCache? _importCache;
  StudioEditorContext? _context;
  StudioPipelineAssets? _assets;
  GameLevelAi? _active;
  GamePlaySession? _play;
  CameraSensor? _camera;
  final _observations = <GameEntityHandle, (ObservationFrame, int)>{};
  void Function()? _cancelRestore;
  (ObservationFrame, int)? historicalObservation(GameEntityHandle actor) =>
      ai.canInspect && _active?.actors.contains(actor) == true
      ? _observations[actor]
      : null;
  int _captureEpoch = 0;
  Future<void>? _closing;
  bool _closed = false;
  SceneRuntime rendering = const SceneRuntime();
  bool get isClosed => _closed;

  Map<String, MlModelManifest> get manifests => _launchManifests;
  GameLevelAi? get activeAi => _active;
  MlDiagnostics? get preparationDiagnostics => _importCache?.diagnostics;
  Map<String, GameRuntimePolicy> get policies => {
    for (final entry in _artifacts.entries)
      entry.key: GameRuntimePolicy.fromArtifact(entry.value),
  };

  StudioEditorContribution contribution(StudioPipelineAssets? assets) =>
      StudioEditorContribution(
        id: 'zyren.ai-host',
        version: 1,
        dependencies: {'zyren.game-editor'},
        attach: (context) {
          if (_context != null || _closed) {
            throw StateError('Attach one AI host per editor.');
          }
          _context = context;
          _assets = assets;
          ai.inspectionAllowed = () => _allows('ai.inspect');
          ai.trainingInspectionAllowed = () => _allows('training.inspect');
          ai.trainingAllowed = () => _allows('training.start');
          ai.trainingStopAllowed = () => _allows('training.stop');
          ai.prepareArtifact = prepareArtifact;
          ai.captureCamera = captureCamera;
          ai.activation = ModelActivation(
            currentRevision: () => context.scene.revision,
            apply: activate,
          );
          context.registerOverlay(
            StudioEditorOverlay(
              id: 'ai.permitted-observation',
              builder: (_, _) => ListenableBuilder(
                listenable: ai,
                builder: (_, _) {
                  final actor = ai.selectedActor;
                  final retained = actor == null
                      ? null
                      : historicalObservation(actor);
                  final frame = retained?.$1;
                  return frame == null
                      ? const SizedBox.shrink()
                      : GameObservationOverlay(
                          frame: frame,
                          historicalEpoch: retained!.$2,
                        );
                },
              ),
            ),
          );
          final token = StudioCancellation();
          context.scope.onClose(token.cancel);
          unawaited(
            loadSavedModels(context.scene.capture(), token).then<void>(
              (_) {
                if (context.isActive) ai.refresh();
              },
              onError: (Object error, StackTrace _) {
                if (context.isActive && !token.isCancelled) {
                  ai.error = '$error';
                  ai.refresh();
                }
              },
            ),
          );
          context.scope.onClose(close);
        },
      );

  bool _allows(String scope) =>
      !_closed &&
      _context?.isActive == true &&
      _context!.capabilities.contains(scope);
  void _checkEdit([int? revision]) {
    if (!_allows('studio.edit') ||
        !_allows('ai.inspect') ||
        _context?.isAvailable != true ||
        revision != null && _context!.scene.revision != revision) {
      throw StateError('AI authoring access or editor revision changed.');
    }
  }

  Future<Uint8List> resolveModel(MlModelManifest manifest) async {
    final artifact = _preparing[manifest.sha256] ?? _artifacts[manifest.sha256];
    if (artifact == null ||
        artifact.contract.model.encode() != manifest.encode()) {
      throw StateError('This model is not a validated editor artifact.');
    }
    return artifact.files['actor.onnx']!;
  }

  Map<String, PipelineAssetReference> modelPins(StudioDocument document) =>
      gameAiModelReferences(authoring, document);

  List<String> validation(StudioDocument document) {
    try {
      final pins = modelPins(document);
      final hz = GameLevelAuthoring(authoring).profile(document).fixedHz;
      return [
        for (final pin in pins.values)
          if (_artifacts[pin.sha256] == null)
            'A saved model is unavailable or still being validated.'
          else if (_artifacts[pin.sha256]!.fixedHz != hz)
            'The authored fixed rate differs from the model evaluation.',
        for (final entity in authoring.expanded(document).entities)
          for (final record in entity.components.where(
            (c) => c.type == 'game.ai',
          ))
            if (GameAiAuthoringDefinition(record.data) case final definition)
              if (definition.brain != 'scripted')
                if (_artifacts[definition.modelHash] case final artifact?)
                  if (definition.artifactFamily != artifact.family ||
                      definition.observationSpec.hash !=
                          artifact.contract.observation.hash ||
                      definition.createActions().spec.hash !=
                          artifact.contract.decoder.spec.hash)
                    '${entity.id} has a model from a different sensor or controller profile.',
      ];
    } catch (error) {
      return ['$error'];
    }
  }

  /// Revalidate saved resources before compilation. Missing cache files stay errors.
  Future<void> loadSavedModels(
    StudioDocument document,
    LoadCancellation token,
  ) async {
    final launch = <String, MlModelManifest>{};
    for (final pin in modelPins(document).values) {
      final bundle = await _assets?.cache.get(
        pin.bundleVersion,
        cancellation: token,
      );
      token.throwIfCancelled();
      if (_closed) throw StateError('AI model preparation owner is closed.');
      if (bundle == null) {
        throw StateError('The saved model bundle is unavailable.');
      }
      final prefix = 'model.${pin.sha256}.';
      final artifact =
          ModelArtifact.decode(bundle.resource('${prefix}bundle.json').bytes, {
            for (final name in ModelArtifact.fileNames)
              name: bundle.resource('$prefix$name').bytes,
          });
      final actual = PipelineAssetReference.fromBundle(bundle);
      if (artifact.contract.model.sha256 != pin.sha256 ||
          actual.toJson().toString() != pin.toJson().toString()) {
        throw StateError('Saved model resources differ from their pin.');
      }
      _register(artifact);
      launch[pin.sha256] = artifact.contract.model;
    }
    _launchManifests
      ..clear()
      ..addAll(launch);
  }

  void _register(ModelArtifact artifact) {
    final hash = artifact.contract.model.sha256;
    if (_artifacts.length >= 8 && !_artifacts.containsKey(hash)) {
      throw StateError('Model catalog capacity reached.');
    }
    _artifacts[hash] = artifact;
  }

  Future<ModelImportCandidate> prepareArtifact(
    String path,
    MlCancellationToken token,
  ) async {
    _checkEdit();
    final context = _context!, revision = context.scene.revision;
    final folder = Directory(path);
    final manifest = await _boundedFile(
      File('${folder.path}/bundle.json'),
      65536,
    );
    final files = <String, Uint8List>{};
    var total = manifest.length;
    for (final name in ModelArtifact.fileNames) {
      if (token.isCancelled) throw const ModelImportCancelled();
      final limit = name == 'actor.onnx'
          ? 8388608
          : name == 'evaluation.json'
          ? 16777216
          : 1048576;
      final bytes = await _boundedFile(File('${folder.path}/$name'), limit);
      total += bytes.length;
      if (total > 33554432) {
        throw const FormatException('Model resource budget exceeded.');
      }
      files[name] = bytes;
    }
    final artifact = ModelArtifact.decode(manifest, files);
    _checkEdit(revision);
    if (token.isCancelled || !identical(context, _context)) {
      throw const ModelImportCancelled();
    }
    final hash = artifact.contract.model.sha256;
    if (_preparing.isNotEmpty) {
      throw StateError('A model is already being prepared.');
    }
    _preparing[hash] = artifact;
    final cache = _importCache ??= MlModelCache(manifestResolver: resolveModel);
    late final ModelImportCandidate candidate;
    try {
      candidate =
          await ModelImport(
            cache: cache,
            observation: artifact.contract.observation,
            action: artifact.contract.decoder.spec,
          ).validate(
            artifact.contract,
            evaluation: TrainingEvaluation.fromModel(artifact.evaluation),
            cancellation: token,
          );
    } finally {
      _preparing.remove(hash);
    }
    _checkEdit(revision);
    if (token.isCancelled || !identical(context, _context)) {
      throw const ModelImportCancelled();
    }
    _register(artifact);
    ai.importer = ModelImport(
      cache: cache,
      observation: artifact.contract.observation,
      action: artifact.contract.decoder.spec,
    );
    return candidate;
  }

  Future<void> activate(PolicyContract contract, int revision) async {
    _checkEdit(revision);
    final context = _context!, assets = _assets;
    final artifact = _artifacts[contract.model.sha256];
    if (artifact == null || assets == null) {
      throw StateError('Model assets are unavailable.');
    }
    final before = context.scene.capture(), nodeId = context.selectedId;
    final entity = authoring
        .expanded(before)
        .entities
        .where((e) => e.nodeId == nodeId)
        .firstOrNull;
    if (entity == null || nodeId == null) {
      throw StateError('Select an authored NPC to activate this model.');
    }
    final record = entity.components
        .where((c) => c.type == 'game.ai')
        .firstOrNull;
    if (record == null ||
        GameAiAuthoringDefinition(record.data).artifactFamily !=
            artifact.family) {
      throw StateError('Selected NPC uses a different AI profile.');
    }
    if (GameLevelAuthoring(authoring).profile(before).fixedHz !=
        artifact.fixedHz) {
      throw StateError(
        'The model was evaluated at ${artifact.fixedHz}Hz. Update the authored simulation rate first.',
      );
    }
    final bundle = await _pack(artifact);
    _checkEdit(revision);
    if (context.selectedId != nodeId ||
        context.scene.capture().encode() != before.encode()) {
      throw StateError('The selected NPC changed during model preparation.');
    }
    if (!await assets.cache.put(bundle, pin: true)) {
      throw StateError('The pinned model cache is full.');
    }
    _checkEdit(revision);
    if (context.selectedId != nodeId ||
        context.scene.capture().encode() != before.encode()) {
      throw StateError('The selected NPC changed during model preparation.');
    }
    final fields = {
      'brain': 'hybrid',
      'modelHash': contract.model.sha256,
      'modelReference': PipelineAssetReference.fromBundle(bundle).toJson(),
    };
    await context.applyDocument(
      authoring.setFields(
        before,
        nodeId: nodeId,
        component: 'game.ai',
        fields: fields,
      ),
    );
  }

  List<GameSystem> systems(GamePlaySession play) {
    final gameplay = GamePlayGameplay(play, rules);
    final owner = GameLevelAi(
      runtime: () => play.levelRuntime!,
      cache: play.models!,
      policies: policies,
      onChanged: _refresh,
      openCameraBackend: (_, _) => NativeBackend.create(),
      interact: (actor) {
        final target = gameplay.available(actor).firstOrNull;
        return target != null && gameplay.interact(actor, target.id);
      },
    );
    _active = owner;
    _play = play;
    return [gameplay, ...owner.systems, GamePlayEventJournal()];
  }

  Future<GameRuntimeResourceLease> prepareRuntime(GamePlaySession play) async {
    final owner = _active;
    if (owner == null || !identical(play, _play)) {
      throw StateError('AI runtime owner is missing.');
    }
    try {
      await owner.warmup();
      final restored = play.levelRuntime!.listenRestored(() {
        _observations.clear();
        _captureEpoch++;
        ai.cameras.clear();
        ai.refresh();
      });
      _cancelRestore = restored.dispose;
    } catch (_) {
      await _unbind(owner);
      rethrow;
    }
    return GameRuntimeResourceLease(close: () => _unbind(owner));
  }

  void _refresh() {
    final owner = _active;
    if (_closed || owner == null) return;
    final actors = owner.actors;
    _observations.removeWhere((actor, _) => !actors.contains(actor));
    ai.cameras.removeWhere((actor, _) => !actors.contains(actor));
    for (final actor in actors) {
      final frame = owner.observation(actor);
      if (frame != null) {
        _observations[actor] = (frame, _play!.simulation!.session.epoch);
      }
      if (owner.visualProfile(actor) != null) {
        final pixels = owner.cameraObservation(actor);
        if (pixels == null) {
          ai.cameras.remove(actor);
        } else {
          ai.cameras[actor] = pixels;
        }
      }
    }
    ai.group = owner.group;
    ai.availableActors = () =>
        _allows('ai.inspect') && identical(owner, _active)
        ? owner.actors
        : const [];
    ai.inspectActor = (actor) =>
        _allows('ai.inspect') &&
            identical(owner, _active) &&
            owner.actors.contains(actor)
        ? owner.inspect(actor)
        : null;
    ai.sensors
      ..clear()
      ..addAll(owner.sensorProfiles);
    if (!owner.actors.contains(ai.selectedActor)) {
      ai.selectedActor = owner.actors.firstOrNull;
    }
    ai.refresh();
  }

  /// Freeze the shared clock for one real capture. This does not add policy inputs.
  Future<void> captureCamera() async {
    if (!_allows('ai.inspect')) {
      throw StateError('Camera inspection is denied.');
    }
    final play = _play, owner = _active, actor = ai.selectedActor;
    if (play == null ||
        owner == null ||
        actor == null ||
        !owner.actors.contains(actor)) {
      throw StateError('Select a live NPC during play.');
    }
    if (play.state != GamePlayState.running &&
        play.state != GamePlayState.paused) {
      throw StateError('The play scene is unavailable.');
    }
    final wasRunning = play.state == GamePlayState.running;
    if (wasRunning) play.pause();
    final epoch = _captureEpoch;
    try {
      final level = play.levelRuntime!, session = play.simulation!.session;
      final body = level.resolveBody(actor);
      if (body == null || !session.entities.isAlive(actor)) {
        throw StateError('NPC body is unavailable.');
      }
      final tick = play.tick;
      final snapshot = SensorSnapshot(
        episodeId: owner.group!.episodeId,
        tick: tick,
        worldRevision: tick,
        entities: [SensorEntity(handle: actor, pose: body.state.pose)],
        colliders: const {},
        currentRevision: () =>
            identical(owner, _active) &&
                epoch == _captureEpoch &&
                session.entities.isAlive(actor)
            ? play.tick
            : -1,
        geometryLoaded: (_, _) => false,
      );
      final camera = _camera ??= CameraSensor(
        CameraProfile(depth: true, far: 100, offset: const Vec3(0, .5, 0)),
        openBackend: rendering.createBackend,
      );
      final observation = await camera.capture(
        snapshot: snapshot,
        entity: actor,
        scene: play.runtimeScene!.scene,
      );
      if (!_allows('ai.inspect') ||
          !identical(owner, _active) ||
          epoch != _captureEpoch ||
          ai.selectedActor != actor ||
          !snapshot.isCurrent) {
        throw StateError('NPC capture became stale.');
      }
      ai.cameras
        ..clear()
        ..[actor] = observation;
      ai.refresh();
    } finally {
      if (wasRunning &&
          identical(owner, _active) &&
          epoch == _captureEpoch &&
          play.state == GamePlayState.paused) {
        play.resume();
      }
    }
  }

  Future<void> _unbind(GameLevelAi owner) async {
    if (identical(owner, _active)) {
      _captureEpoch++;
      _cancelRestore?.call();
      _cancelRestore = null;
      _observations.clear();
      _active = null;
      _play = null;
      ai.group = null;
      ai.inspectActor = null;
      ai.availableActors = null;
      ai.selectedActor = null;
      ai.sensors.clear();
      ai.cameras.clear();
      ai.refresh();
      final camera = _camera;
      _camera = null;
      try {
        await camera?.close();
      } finally {
        await owner.close();
      }
      return;
    }
    await owner.close();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    ai.permitted = false;
    Object? first;
    StackTrace? trace;
    Future<void> cleanup(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        first ??= error;
        trace ??= stack;
      }
    }

    final owner = _active;
    if (owner != null) await cleanup(() => _unbind(owner));
    await cleanup(ai.close);
    await cleanup(() async {
      await _importCache?.close();
    });
    ai.dispose();
    _context = null;
    if (first != null) Error.throwWithStackTrace(first!, trace!);
  }
}

Future<Uint8List> _boundedFile(File file, int limit) async {
  if (!await file.exists() || await file.length() > limit) {
    throw const FormatException('Model file is missing or oversized.');
  }
  final input = await file.open();
  try {
    final bytes = await input.read(limit + 1);
    if (bytes.length > limit) {
      throw const FormatException('Model file grew beyond its budget.');
    }
    return bytes;
  } finally {
    await input.close();
  }
}

Future<PipelineBundle> _pack(ModelArtifact artifact) async {
  final bytes = {'bundle.json': artifact.manifestBytes, ...artifact.files};
  final hash = artifact.contract.model.sha256, prefix = 'model.$hash.';
  final sources = {
    for (final name in bytes.keys)
      Uri.parse('model:///$hash/$name'): bytes[name]!,
  };
  return PipelineBuilder(resolver: _ArtifactBytes(sources)).build(
    entrySourceId: '${prefix}actor.onnx',
    sources: [
      for (final entry in sources.entries)
        PipelineSource(
          sourceId: '$prefix${entry.key.pathSegments.last}',
          revision: sha256.convert(entry.value).toString(),
          uri: entry.key,
        ),
    ],
  );
}

final class _ArtifactBytes implements ByteSourceResolver {
  final Map<Uri, Uint8List> bytes;
  _ArtifactBytes(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final value = bytes[uri];
    if (value == null || value.length > context.maxBytes) {
      throw StateError('Model source is missing or oversized.');
    }
    return ResolvedSource(effectiveUri: uri, bytes: value);
  }
}
