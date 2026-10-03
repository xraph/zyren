import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_studio/gameplay.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'saved template plays the key gate checkpoint and vehicle loop through real physics',
    () async {
      final library = GameRuleLibrary(),
          authoring = createGameDevelopmentAuthoring();
      final source = GameTemplate(
        GameTemplateKind.vehiclePlayground,
        authoring,
      ).create(projectId: 'native-rules').document;
      final document = StudioDocument.decode(source.encode());
      final build =
          await GameProjectCompiler(
            registry: authoring.registry,
            assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
          ).compile(
            documents: [document],
            startupLevel: 'main',
            profile: GameBuildProfile(id: 'native'),
          );
      expect(
        build.status,
        GameBuildStatus.ready,
        reason: '${build.diagnostics}',
      );
      final scene = StudioScene(document);
      late GamePlayGameplay gameplay;
      final play = GamePlaySession(
        authoredScene: scene,
        fixtureRendererFactory: () async => _Renderer(),
        systemFactory: (play) => [
          gameplay = GamePlayGameplay(play, library),
          GamePlayEventJournal(),
        ],
      );
      try {
        await play.start(build.artifact!.project);
        final actor = play.inputActor!;
        void advance([int count = 12]) {
          for (var i = 0; i < count; i++) {
            play.simulation!.step();
          }
        }

        void move(Vec3 position) {
          play.resolveBody(actor)!.teleport(PhysicsPose(position: position));
          advance(2);
        }

        move(const Vec3(0, 1, 1));
        expect(gameplay.interact(actor, 'pickup-key'), isTrue);
        advance();
        expect(gameplay.authored.hasItem(actor, 'key', 1), isTrue);
        expect(play.runtimeScene!.objects['key']!.visible, isFalse);
        move(const Vec3(0, 1, 4.5));
        expect(gameplay.interact(actor, 'open-gate'), isTrue);
        advance();
        expect(gameplay.authored.objectiveComplete(actor, 'gate'), isTrue);
        expect(play.runtimeScene!.objects['gate']!.visible, isFalse);
        final hit = play.world!.rayCast(
          origin: const Vec3(0, 1.2, 4.5),
          direction: const Vec3(0, 0, 1),
          maxDistance: 3,
          filter: QueryFilter(
            excludeBody: play.resolveBody(actor),
            excludeSensors: true,
          ),
        );
        expect(
          hit,
          isNull,
          reason: 'Opened gate no longer blocks the native physics ray.',
        );
        move(const Vec3(0, 1, 9));
        advance();
        expect(
          gameplay.authored.objectiveComplete(actor, 'checkpoint'),
          isTrue,
        );
        final vehicle = play.vehicles.keys.single;
        final position = play.resolveBody(vehicle)!.state.pose.position;
        move(position + const Vec3(0, .3, 1.5));
        expect(gameplay.interact(actor, 'enter-vehicle'), isTrue);
        advance();
        expect(play.controlledActor, vehicle);
        play.pause();
        play.step();
        play.resume();
        expect(play.controlledActor, vehicle);
        expect(play.controlEntity(actor), isTrue);
        expect(
          play
              .resolveBody(actor)!
              .state
              .pose
              .position
              .distanceTo(play.resolveBody(vehicle)!.state.pose.position),
          lessThan(3),
        );
        expect(scene.capture().encode(), source.encode());
      } finally {
        await play.stop();
        play.dispose();
      }
    },
  );
}

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'gameplay-attachment',
    features: {RenderFeatures.indexedMeshes},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}
