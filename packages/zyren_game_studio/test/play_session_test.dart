import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_studio/authoring.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_studio/zyren_studio.dart';

class TestRenderer implements SceneRenderer {
  bool closed = false;
  @override
  final capabilities = RendererCapabilities(
    name: 'native-lifetime-fixture',
    features: {RenderFeatures.indexedMeshes, RenderFeature.portablePrimitives},
    maxDimension: 1024,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {
    closed = true;
  }
}

class DelayedRenderer extends TestRenderer {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> dispose() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.dispose();
  }
}

CompiledGameProject compile(StudioDocument d, GameAuthoring a) {
  final data = a.expanded(d);
  return CompiledGameProject(
    project: GameProject(
      id: data.projectId,
      startupLevel: data.levelId,
      levels: [
        GameLevel(
          id: data.levelId,
          scene: GameSceneIdentity(
            d.id,
            sha256.convert(utf8.encode(d.encode())).toString(),
          ),
          entities: data.entities,
        ),
      ],
      registry: a.registry,
    ),
    sceneNodes: {
      data.levelId: d.expandedNodes.values.map((n) => n.toJson()).toList(),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stop drains runtime preparation before releasing native owners',
    () async {
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'prepare-cancel').document;
      final entered = Completer<void>(), release = Completer<void>();
      var renderers = 0, preparationCloses = 0;
      late PhysicsWorld world;
      final play = GamePlaySession(
        authoredScene: StudioScene(document),
        fixtureRendererFactory: () async {
          renderers++;
          return TestRenderer();
        },
        prepareRuntime: (play) async {
          world = play.world!;
          entered.complete();
          await release.future;
          expect(world.isClosed, isFalse);
          return GameRuntimeResourceLease(
            close: () {
              expect(world.isClosed, isFalse);
              preparationCloses++;
            },
          );
        },
      );
      final launching = expectLater(
        play.start(compile(document, authoring)),
        throwsA(isA<LoadCancelled>()),
      );
      await entered.future;
      var stopped = false;
      final stopping = play.stop().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      release.complete();
      await launching;
      await stopping;
      expect(world.isClosed, isTrue);
      expect(renderers, 0);
      expect(preparationCloses, 1);
      expect(play.world, isNull);
      play.dispose();
    },
  );
  test(
    'three real native sessions own independent worlds, models and unchanged authoring',
    () async {
      final authoring = createGameDevelopmentAuthoring(),
          document = GameTemplate(
            GameTemplateKind.exploration,
            createGameDevelopmentAuthoring(),
          ).create(projectId: 'native-play').document;
      final scene = StudioScene(document);
      final before = scene.capture().encode();
      final project = compile(document, authoring);
      for (var i = 0; i < 3; i++) {
        final renderer = TestRenderer();
        final play = GamePlaySession(
          authoredScene: scene,
          fixtureRendererFactory: () async => renderer,
          audioFactory: (s) {
            s.scene.add(s.camera);
            return SpatialAudio(
              root: s.scene,
              listener: AudioListener(s.camera),
              offline: true,
            );
          },
        );
        await play.start(project);
        final world = play.simulation!.world,
            cache = play.models!,
            audio = play.audio!;
        expect(play.runtimeScene, isNot(same(scene)));
        expect(world.states, isNotEmpty);
        final actor = play.simulation!.session.entities.entities
            .firstWhere((e) => e.handle.id == 'player')
            .handle;
        play.runtimeSelection = actor;
        expect(play.inspectEntity(actor)['controller'], 'primitive');
        play.pause();
        final tick = play.tick;
        expect(audio.isSuspended, isTrue);
        play.step();
        expect(play.tick, tick + 1);
        expect(play.isPaused, isTrue);
        expect(audio.isSuspended, isTrue);
        play.resume();
        expect(audio.isSuspended, isFalse);
        play.actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
        for (var j = 0; j < 10; j++) {
          play.simulation!.step();
        }
        expect(play.resolveBody(actor)!.state.pose.position.z, greaterThan(.1));
        await play.stop();
        expect(world.isClosed, isTrue);
        expect(renderer.closed, isTrue);
        expect(audio.isClosed, isTrue);
        expect(cache.diagnostics.residentModels, 0);
        expect(scene.capture().encode(), before);
        expect(scene.canUndo, isFalse);
        play.dispose();
      }
    },
  );
  test(
    'native runtime transforms apply back only after a selected revision check',
    () async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'apply-native').document;
      final scene = StudioScene(d), before = scene.capture().encode();
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await play.start(compile(scene.document, a));
      final actor = play.inputActor!;
      play.actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
      for (var i = 0; i < 20; i++) {
        play.simulation!.step();
      }
      play.pause();
      final apply = GameApplyBack(scene: scene, authoring: a);
      final diff = apply.prepare(play.authoredRevision!, play.snapshot());
      final position = diff.fields.singleWhere(
        (f) => f.nodeId == actor.id && f.path == 'transform.position',
      );
      final world = play.simulation!.world;
      await play.stop();
      expect(world.isClosed, isTrue);
      apply.commit(
        diff,
        expectedRevision: scene.revision,
        selectedFields: {position.id},
      );
      expect(
        scene.document.nodes.singleWhere((n) => n.id == actor.id).position.z,
        greaterThan(.1),
      );
      scene.undo();
      expect(scene.document.encode(), before);
      scene.redo();
      expect(
        scene.document.nodes.singleWhere((n) => n.id == actor.id).position.z,
        greaterThan(.1),
      );
      play.dispose();
    },
  );
  test(
    'vehicle play routes the player map through one possession lease',
    () async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.vehiclePlayground,
        a,
      ).create(projectId: 'vehicle-native').document;
      final scene = StudioScene(d);
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await play.start(compile(scene.document, a));
      final player = play.inputActor!, target = play.vehicles.keys.single;
      final position = play.resolveBody(target)!.state.pose.position;
      play
          .resolveBody(player)!
          .teleport(PhysicsPose(position: position + const Vec3(2, 1, 0)));
      expect(play.controlEntity(target), isTrue);
      final actions = play.actions;
      actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
      for (var i = 0; i < 120; i++) {
        play.simulation!.step();
      }
      expect(play.vehicles[target]!.forceTicks, 121);
      expect(
        play.resolveBody(target)!.state.pose.position.z,
        greaterThan(position.z + 1),
      );
      expect(play.actions, same(actions));
      play.pause();
      expect(play.possession!.seatOf(player), isNull);
      final tick = play.tick;
      play.step();
      expect(play.tick, tick + 1);
      expect(play.controlledActor, target);
      expect(play.possession!.seatOf(player), isNull);
      play.resume();
      expect(play.controlledActor, target);
      expect(play.possession!.seatOf(player), target.id);
      final exit = play.exitPlacement(player, target)!;
      final obstruction = play.world!.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: exit.position + const Vec3(.3, .45, 0)),
      );
      final blocked = obstruction.addCollider(
        const BoxShape(Vec3(.08, .1, .2)),
      );
      expect(play.controlEntity(player), isFalse);
      expect(play.controlledActor, target);
      blocked.remove();
      obstruction.remove();
      final validated = play.exitPlacement(player, target)!;
      expect(play.controlEntity(player), isTrue);
      expect(
        (play.resolveBody(player)!.state.pose.position - validated.position)
            .length,
        lessThan(.0001),
      );
      expect(play.controlledActor, player);
      expect(play.possession!.seatOf(player), player.id);
      await play.stop();
      play.dispose();
    },
  );

  test(
    'runtime activation restores authored visibility and collision without new handles',
    () async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'activation').document;
      final scene = StudioScene(d), before = scene.capture().encode();
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await play.start(compile(d, a));
      final gate = play.simulation!.session.entities.entities
          .singleWhere((e) => e.handle.id == 'gate')
          .handle;
      final body = play.resolveBody(gate)!;
      bool hit() =>
          play.world!.rayCast(
            origin: const Vec3(0, 1.2, 4),
            direction: const Vec3(0, 0, 1),
            maxDistance: 3,
            filter: QueryFilter(excludeSensors: true),
          ) !=
          null;
      expect(hit(), isTrue);
      play.setEntityActive(gate, false);
      expect(play.runtimeScene!.objects['gate']!.visible, isFalse);
      expect(hit(), isFalse);
      play.setEntityActive(gate, true);
      expect(play.runtimeScene!.objects['gate']!.visible, isTrue);
      expect(hit(), isTrue);
      expect(play.resolveBody(gate), same(body));
      expect(scene.capture().encode(), before);
      await play.stop();
      expect(() => play.setEntityActive(gate, false), throwsStateError);
      play.dispose();
    },
  );
  test('start cannot overlap an asynchronous stop cleanup', () async {
    final a = createGameDevelopmentAuthoring();
    final d = GameTemplate(
      GameTemplateKind.exploration,
      a,
    ).create(projectId: 'cleanup').document;
    final renderer = DelayedRenderer();
    final play = GamePlaySession(
      authoredScene: StudioScene(d),
      fixtureRendererFactory: () async => renderer,
    );
    final project = compile(d, a);
    await play.start(project);
    final world = play.world!;
    final stopping = play.stop();
    await renderer.entered.future;
    expect(() => play.start(project), throwsStateError);
    renderer.release.complete();
    await stopping;
    expect(world.isClosed, isTrue);
    await play.start(project);
    expect(play.world, isNot(same(world)));
    await play.stop();
    play.dispose();
  });
  test(
    'native collider launch rejects reflected and sheared world transforms',
    () async {
      final a = createGameDevelopmentAuthoring();
      final base = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'transforms').document;
      for (final reflected in [true, false]) {
        final d = base.copyWith(
          nodes: [
            if (!reflected)
              StudioNode(
                id: 'scaled-parent',
                label: 'Scaled parent',
                kind: StudioNodeKind.group,
                scale: const Vec3(2, 1, 1),
              ),
            for (final n in base.nodes)
              n.id != 'player'
                  ? n
                  : (reflected
                        ? n.copyWith(scale: const Vec3(-1, 1, 1))
                        : n.copyWith(
                            parentId: 'scaled-parent',
                            rotation: Quat.axisAngle(const Vec3(0, 1, 0), .7),
                          )),
          ],
        );
        final scene = StudioScene(d), before = scene.capture().encode();
        final play = GamePlaySession(
          authoredScene: scene,
          fixtureRendererFactory: () async => TestRenderer(),
        );
        await expectLater(play.start(compile(d, a)), throwsStateError);
        expect(play.world, isNull);
        expect(play.models, isNull);
        expect(scene.capture().encode(), before);
        await play.stop();
        play.dispose();
      }
    },
  );
  test(
    'native initialization failure retires world before loaded assets',
    () async {
      final a = createGameDevelopmentAuthoring();
      var d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'failure').document;
      d = d.copyWith(
        nodes: [
          ...d.nodes,
          StudioNode(
            id: 'import',
            label: 'Import',
            kind: StudioNodeKind.asset,
            assetId: 'model',
          ),
        ],
        assets: [
          StudioAsset(
            id: 'model',
            label: 'Model',
            provider: 'fixture',
            reference: {'revision': '1'},
            sourceNodes: {},
          ),
        ],
      );
      final scene = StudioScene(
        d,
        assets: await StudioAssetScope.load(d, Resolver()),
      );
      final resolver = Resolver();
      final play = GamePlaySession(
        authoredScene: scene,
        assetResolver: resolver,
        fixtureRendererFactory: () async =>
            throw StateError('native renderer failed'),
      );
      await expectLater(play.start(compile(d, a)), throwsStateError);
      expect(play.state, GamePlayState.failed);
      expect(play.simulation, isNull);
      expect(resolver.templates.single.closed, isTrue);
      await play.stop();
      await scene.assets!.close();
      play.dispose();
    },
  );
  test(
    'cancelled asset launch and concurrent launch are retired without authoring edits',
    () async {
      final a = createGameDevelopmentAuthoring();
      var d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'cancel').document;
      d = d.copyWith(
        nodes: [
          ...d.nodes,
          StudioNode(
            id: 'import',
            label: 'Import',
            kind: StudioNodeKind.asset,
            assetId: 'model',
          ),
        ],
        assets: [
          StudioAsset(
            id: 'model',
            label: 'Model',
            provider: 'fixture',
            reference: {'revision': '1'},
            sourceNodes: {},
          ),
        ],
      );
      final scene = StudioScene(
        d,
        assets: await StudioAssetScope.load(d, Resolver()),
      );
      final before = scene.capture().encode();
      final resolver = Resolver()..gate = Completer<void>();
      final play = GamePlaySession(
        authoredScene: scene,
        assetResolver: resolver,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      final pending = play.start(compile(d, a));
      expect(
        () => GamePlaySession(authoredScene: scene).start(compile(d, a)),
        throwsStateError,
      );
      final closed = play.stop();
      resolver.gate!.complete();
      await expectLater(pending, throwsA(isA<LoadCancelled>()));
      await closed;
      expect(resolver.templates.single.closed, isTrue);
      expect(scene.capture().encode(), before);
      await scene.assets!.close();
      play.dispose();
    },
  );
  test(
    'model and asset failures release their launch owner for a later launch',
    () async {
      final a = createGameDevelopmentAuthoring(),
          d = GameTemplate(
            GameTemplateKind.exploration,
            createGameDevelopmentAuthoring(),
          ).create(projectId: 'pins').document;
      final scene = StudioScene(d), project = compile(d, a);
      final withModels = CompiledGameProject(
        project: GameProject(
          id: project.id,
          startupLevel: project.project.startupLevel,
          levels: project.levels,
          registry: a.registry,
          modelReferences: {
            'policy': {'digest': 'bad'},
          },
        ),
        sceneNodes: project.sceneNodes,
      );
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await expectLater(play.start(withModels), throwsStateError);
      await play.stop();
      await play.start(project);
      await play.stop();
      play.dispose();
    },
  );
  test(
    'real native model sessions are isolated and invalid model bytes retire the cache',
    () async {
      final a = createGameDevelopmentAuthoring();
      final d = GameTemplate(
        GameTemplateKind.exploration,
        a,
      ).create(projectId: 'models-native').document;
      final scene = StudioScene(d), base = compile(d, a);
      final manifest = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/linear.json').readAsStringSync(),
      );
      CompiledGameProject recipe(String digest) => CompiledGameProject(
        project: GameProject(
          id: base.id,
          startupLevel: base.project.startupLevel,
          levels: base.levels,
          registry: a.registry,
          modelReferences: {
            'policy': PipelineAssetReference(
              bundleVersion: digest,
              sourceId: 'policy-model',
              sourceRevision: '1',
              sha256: digest,
              uri: Uri.parse('game:///model'),
            ).toJson(),
          },
        ),
        sceneNodes: base.sceneNodes,
        assets: [
          GameAssetReference(
            id: 'policy-model',
            revision: '1',
            uri: Uri.parse('game:///model'),
            digest: digest,
          ),
        ],
        artifactHashes: {'policy-model': digest},
      );
      final baseline = const MlRuntime().diagnostics.liveSessions;
      final play = GamePlaySession(
        authoredScene: scene,
        modelManifests: {'policy': manifest},
        modelResolver: (path) =>
            File('../zyren_ml/test/fixtures/$path').readAsBytes(),
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await play.start(recipe(manifest.sha256));
      expect(play.models!.diagnostics.residentModels, 1);
      expect(const MlRuntime().diagnostics.liveSessions, baseline + 1);
      final cache = play.models;
      await play.stop();
      expect(const MlRuntime().diagnostics.liveSessions, baseline);
      await play.start(recipe(manifest.sha256));
      expect(play.models, isNot(same(cache)));
      await play.stop();
      play.dispose();
      final badBytes = Uint8List.fromList([1, 2, 3]),
          hash = sha256.convert([1, 2, 3]).toString();
      final invalid = MlModelManifest.decode(
        jsonEncode(
          jsonDecode(manifest.encode()) as Map<String, dynamic>
            ..['sha256'] = hash,
        ),
      );
      final failing = GamePlaySession(
        authoredScene: scene,
        modelManifests: {'policy': invalid},
        modelResolver: (_) async => badBytes,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await expectLater(
        failing.start(recipe(hash)),
        throwsA(isA<MlLoadException>()),
      );
      expect(failing.models, isNull);
      expect(const MlRuntime().diagnostics.liveSessions, baseline);
      await failing.stop();
      failing.dispose();
    },
  );
  test(
    'compiled revision mismatch is rejected before allocating native physics',
    () async {
      final a = createGameDevelopmentAuthoring(),
          d = GameTemplate(
            GameTemplateKind.exploration,
            createGameDevelopmentAuthoring(),
          ).create(projectId: 'stale').document;
      final scene = StudioScene(d), project = compile(d, a);
      scene.apply(d.copyWith(title: 'Changed'));
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => TestRenderer(),
      );
      await expectLater(play.start(project), throwsStateError);
      expect(play.simulation, isNull);
      await play.stop();
      play.dispose();
    },
  );
}

class Resolver implements StudioAssetResolver {
  Completer<void>? gate;
  final templates = <Template>[];
  @override
  Future<StudioAssetTemplate> load(
    StudioAsset asset,
    LoadCancellation cancellation,
  ) async {
    await gate?.future;
    final template = Template();
    templates.add(template);
    return template;
  }
}

class Template implements StudioAssetTemplate {
  bool closed = false;
  @override
  StudioAssetInstance instantiate() => StudioAssetInstance(Group());
  @override
  Future<void> close() async {
    closed = true;
  }
}
