import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_physics/zyren_physics.dart';

final class _GamePhysics extends GameSystem {
  final PhysicsWorld world;
  int steps = 0;
  _GamePhysics(this.world);
  @override
  String get id => 'physics';
  @override
  GamePhase get phase => GamePhase.physics;
  @override
  void fixedUpdate(GameSession session) {
    world.step();
    steps++;
  }
}

final class _GameTime extends GameSystem {
  final GeoExternalClock time;
  final DateTime epoch = DateTime.utc(2026, 10, 3);
  _GameTime(this.time);
  @override
  String get id => 'geospatial-clock';
  @override
  GamePhase get phase => GamePhase.sensors;
  @override
  Set<String> get dependencies => {'physics'};
  @override
  void fixedUpdate(GameSession session) {
    time.accept(
      GeoInstant(tick: session.tick, hz: session.fixedHz, epoch: epoch),
    );
  }
}

final class _Observer extends GeoSimulationSystem {
  final PhysicsBody body;
  GeoSample<Vec3>? sample;
  _Observer(this.body);
  @override
  String get id => 'body-observation';
  @override
  int get requiredHz => 60;
  @override
  void step(GeoInstant instant) {
    sample = GeoSample(
      availability: GeoSampleAvailability.available,
      value: body.state.pose.position,
      frameId: 'local-enu',
      frameRevision: 0,
      sourceRevision: 'physics-fixture-v1',
      time: instant,
      units: 'm',
    );
  }
}

final class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'clock-fixture',
    features: {},
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

void main() {
  test(
    'game tick owns native physics while render and geospatial sampling do not step it',
    () async {
      final baseline = PhysicsWorld.nativeCounts;
      final physics = PhysicsWorld(gravity: Vec3.zero);
      final body = physics.createBody(
        velocity: const Vec3(1, 0, 0),
        canSleep: false,
      );
      body.addCollider(const SphereShape(.5));
      final physicsSystem = _GamePhysics(physics);
      final external = GeoExternalClock();
      final project = CompiledGameProject(
        project: GameProject(
          id: 'clock-fixture',
          startupLevel: 'world',
          levels: [
            GameLevel(
              id: 'world',
              scene: GameSceneIdentity('world', 'v1'),
              entities: [],
            ),
          ],
          registry: GameRegistry(),
        ),
        fixedHz: 60,
      );
      final game = GameSession(
        project: project,
        seed: 1,
        systems: [physicsSystem, _GameTime(external)],
      );
      final observer = _Observer(body);
      final simulation = GeoSimulation(
        systems: [observer],
      ).acquireDriver('application');
      final geo = GeospatialPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        plugins: geo.scenePlugins,
        rendererFactory: () async => _Renderer(),
      );
      try {
        for (var i = 0; i < 60; i++) {
          game.step();
          await simulation.step(external.instant);
        }
        expect(physicsSystem.steps, 60);
        expect(body.state.pose.position.x, closeTo(1, .0001));
        final before = body.state.pose.position;
        game.pause();
        expect(game.advance(20), 0);
        for (var i = 0; i < 10; i++) {
          engine.camera.position = Vec3(i.toDouble(), 0, 10);
          await engine.render(
            elapsed: Duration(seconds: i + 1),
            width: 16,
            height: 16,
          );
        }
        expect(game.tick, 60);
        expect(geo.clock.tick, 0);
        expect(physicsSystem.steps, 60);
        expect(body.state.pose.position, before);
        expect(observer.sample!.time, external.instant);
        expect(external.accept(external.instant), isFalse);
      } finally {
        await engine.dispose();
        simulation.dispose();
        await simulation.whenClosed;
        await game.close();
        physics.close();
      }
      expect(PhysicsWorld.nativeCounts, baseline);
    },
  );
}
