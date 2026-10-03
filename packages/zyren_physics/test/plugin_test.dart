import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

class _Renderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'test',
    features: {
      RenderFeatures.indexedMeshes,
      RenderFeatures.rgbaReadback,
      RenderFeature.portablePrimitives,
    },
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
  Future<void> dispose() async {}
}

class _Writer extends ScenePlugin {
  final Object3D object;
  _Writer(this.object);
  @override
  String get id => 'competing-writer';
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    object.position = const Vec3(20, 0, 0);
  }
}

void main() {
  test(
    'external driver advances once per game tick at every render cadence',
    () async {
      for (final renderHz in [30, 60, 120]) {
        final world = PhysicsWorld(gravity: Vec3.zero);
        final body = world.createBody(velocity: const Vec3(1, 0, 0));
        body.addCollider(const SphereShape(.1));
        var steps = 0;
        final plugin = PhysicsPlugin(
          world: world,
          externallyDriven: true,
          interpolate: false,
          beforeStep: (_) => steps++,
        );
        final scene = Scene();
        final object = scene.add(Group());
        plugin.bind(object, body);
        final engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          rendererFactory: () async => _Renderer(),
          plugins: [plugin],
        );
        try {
          await engine.render(elapsed: Duration.zero, width: 8, height: 8);
          for (var frame = 1; frame <= renderHz; frame++) {
            final due = frame * 60 ~/ renderHz;
            while (steps < due) {
              plugin.advance(world.fixedStep);
            }
            final position = body.state.pose.position;
            await engine.render(
              elapsed: Duration(
                microseconds: (frame * 1000000 / renderHz).round(),
              ),
              width: 8,
              height: 8,
            );
            expect(body.state.pose.position, position);
          }
          expect(steps, 60);
          expect(body.state.pose.position.x, closeTo(1, .001));
          plugin.paused = true;
          plugin.advance(world.fixedStep);
          expect(steps, 60);
          plugin.paused = false;
          plugin.advance(world.fixedStep);
          expect(steps, 61);
        } finally {
          await engine.dispose();
          plugin.clearBindings();
          world.close();
        }
      }
    },
  );
  test('bounded stepping, pause, interpolation and competing transforms', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    final plugin = PhysicsPlugin(
      world: world,
      maxCatchUpSteps: 2,
      maxFrameDelta: .25,
    );
    final scene = Scene(), object = Group();
    scene.add(object);
    final body = world.createBody(velocity: const Vec3(1, 0, 0));
    body.addCollider(const SphereShape(.1));
    plugin.bind(object, body);
    try {
      plugin.advance(world.fixedStep * 1.5);
      expect(object.position.x, closeTo(world.fixedStep * .5, 1e-5));
      plugin.paused = true;
      final before = body.state.pose.position;
      plugin.advance(1);
      expect(body.state.pose.position, before);
      plugin.paused = false;
      plugin.advance(1);
      expect(plugin.droppedSeconds, greaterThan(.9));
      object.position = const Vec3(10, 0, 0);
      expect(() => plugin.advance(.01), throwsStateError);
      plugin.unbind(object);
      plugin.bind(object, body);
      object.scale = const Vec3(2, 1, 1);
      expect(() => plugin.advance(.01), throwsUnsupportedError);
      plugin.clearBindings();
    } finally {
      plugin.clearBindings();
      world.close();
    }
  });
  test('rigid parent pose conversion and reparent rejection', () {
    final world = PhysicsWorld(gravity: Vec3.zero),
        plugin = PhysicsPlugin(world: PhysicsWorld(gravity: Vec3.zero));
    try {
      final scene = Scene(),
          parent = Group()
            ..position = const Vec3(4, 0, 0)
            ..quaternion = Quat.axisAngle(const Vec3(0, 1, 0), 1),
          object = Group();
      scene.add(parent);
      parent.add(object);
      final body = plugin.world.createBody(
        pose: PhysicsPose(position: const Vec3(5, 2, 0)),
      );
      plugin.bind(object, body);
      expect(
        parent.quaternion.rotate(object.position) + parent.position,
        const Vec3(5, 2, 0),
      );
      scene.add(object);
      expect(() => plugin.advance(.01), throwsStateError);
    } finally {
      plugin.clearBindings();
      plugin.world.close();
      world.close();
    }
  });
  test('detach, reattach, resize, debug cleanup and failed attach', () async {
    final world = PhysicsWorld(), scene = Scene();
    final body = world.createBody();
    body.addCollider(const SphereShape(.5));
    final object = scene.add(Group()),
        plugin = PhysicsPlugin(world: world, debug: true);
    plugin.bind(object, body);
    Future<SceneEngine> create() => SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => _Renderer(),
      plugins: [plugin],
    );
    try {
      for (var i = 0; i < 2; i++) {
        final engine = await create();
        await engine.render(elapsed: Duration.zero, width: 320, height: 200);
        await engine.render(
          elapsed: const Duration(milliseconds: 20),
          width: 200,
          height: 320,
        );
        expect(scene.children.any((c) => c.name == 'Physics debug'), isTrue);
        await engine.dispose();
        expect(scene.children.any((c) => c.name == 'Physics debug'), isFalse);
        expect(world.isClosed, isFalse);
      }
      plugin.clearBindings();
      final other = Group();
      plugin.bind(other, body);
      await expectLater(create(), throwsStateError);
      plugin.clearBindings();
      final engine = await create();
      await engine.dispose();
    } finally {
      plugin.clearBindings();
      world.close();
    }
  });

  test('one world has one driver and failed attachment preserves it', () async {
    final world = PhysicsWorld(gravity: Vec3.zero);
    final first = PhysicsPlugin(world: world);
    final second = PhysicsPlugin(world: world);
    Future<SceneEngine> create(PhysicsPlugin plugin) => SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => _Renderer(),
      plugins: [plugin],
    );
    SceneEngine? engine;
    try {
      engine = await create(first);
      await expectLater(create(second), throwsStateError);
      expect(() => second.advance(.02), throwsStateError);
      await engine.render(elapsed: Duration.zero, width: 40, height: 40);
      await engine.dispose();
      engine = await create(second);
      await engine.render(elapsed: Duration.zero, width: 40, height: 40);
    } finally {
      await engine?.dispose();
      world.close();
    }
  });

  test('events can remove a body and every associated scene binding', () {
    final world = PhysicsWorld(gravity: Vec3.zero), scene = Scene();
    final first = scene.add(Group()), second = scene.add(Group());
    var callbacks = 0;
    late final PhysicsPlugin plugin;
    plugin = PhysicsPlugin(
      world: world,
      onEvents: (events) {
        expect(() => events.clear(), throwsUnsupportedError);
        if (events.any((e) => e.started)) {
          callbacks++;
          plugin.removeBody(first);
          world.overlap(shape: const SphereShape(4), pose: PhysicsPose());
        }
      },
    );
    try {
      world
          .createBody(kind: BodyKind.fixed)
          .addCollider(const SphereShape(2), sensor: true);
      final body = world.createBody();
      body.addCollider(const SphereShape(.5));
      plugin.bind(first, body);
      plugin.bind(second, body);
      plugin.advance(world.fixedStep);
      expect(callbacks, 1);
      expect(body.isAlive, isFalse);
      plugin.advance(world.fixedStep);
      expect(world.states, hasLength(1));
      second.position = const Vec3(5, 0, 0);
      plugin.advance(world.fixedStep);
    } finally {
      plugin.clearBindings();
      world.close();
    }
  });

  test(
    'later plugin writes fail and the world can attach after failure',
    () async {
      final world = PhysicsWorld(), scene = Scene();
      final object = scene.add(Group()), plugin = PhysicsPlugin(world: world);
      final body = world.createBody();
      body.addCollider(const SphereShape(.5));
      plugin.bind(object, body);
      SceneEngine? engine;
      try {
        engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          rendererFactory: () async => _Renderer(),
          plugins: [plugin, _Writer(object)],
        );
        await expectLater(
          engine.render(elapsed: Duration.zero, width: 40, height: 40),
          throwsStateError,
        );
        await engine.dispose();
        plugin.clearBindings();
        plugin.bind(object, body);
        engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          rendererFactory: () async => _Renderer(),
          plugins: [plugin],
        );
        await engine.render(elapsed: Duration.zero, width: 40, height: 40);
        expect(body.isAlive, isTrue);
      } finally {
        await engine?.dispose();
        plugin.clearBindings();
        world.close();
      }
    },
  );
}
