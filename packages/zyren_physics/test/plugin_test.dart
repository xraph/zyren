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

void main() {
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
}
