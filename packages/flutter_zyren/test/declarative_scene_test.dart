import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show host, frames, readback, runtime;

void main() {
  testWidgets('rebuilds retain mesh, geometry, camera and native session', (
    tester,
  ) async {
    final backend = FakeBackend();
    final sceneRuntime = runtime(backend);
    final ref = SceneRef<Mesh>();
    late SceneController controller;
    var creations = 0;
    Widget scene(Color3 color, {Vec3 position = Vec3.zero}) => host(
      SceneCanvas(
        options: readback,
        runtime: sceneRuntime,
        onCreated: (value) {
          controller = value;
          creations++;
        },
        children: [
          MeshNode(
            ref: ref,
            geometry: SceneGeometry.box(),
            material: SceneMaterial.unlit(color: color),
            position: position,
          ),
        ],
      ),
    );
    await tester.pumpWidget(scene(const Color3(1, 0, 0)));
    await frames(tester);
    final mesh = ref.require, geometry = ref.require.geometry;
    final camera = controller.camera;
    camera.position = const Vec3(2, 3, 4);
    final submissions = backend.submissions.length;
    await tester.pumpWidget(
      scene(const Color3(0, 1, 0), position: const Vec3(1, 0, 0)),
    );
    await frames(tester);
    expect(ref.require, same(mesh));
    expect(ref.require.geometry, same(geometry));
    expect(ref.require.material.color, const Color3(0, 1, 0));
    expect(ref.require.position, const Vec3(1, 0, 0));
    expect(controller.camera, same(camera));
    expect(camera.position, const Vec3(2, 3, 4));
    expect(creations, 1);
    expect(backend.submissions.length, greaterThan(submissions));
    expect(backend.closeCount, 0);
    final idle = backend.submissions.length;
    await frames(tester);
    expect(backend.submissions.length, idle);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
    expect(ref.current, isNull);
    expect(backend.closeCount, 1);
  });

  testWidgets('geometry replacement reparents children and updates refs', (
    tester,
  ) async {
    final sceneRuntime = runtime(FakeBackend());
    final ref = SceneRef<Mesh>(), child = SceneRef<Group>();
    Widget scene(SceneGeometry geometry) => host(
      SceneCanvas(
        runtime: sceneRuntime,
        options: readback,
        children: [
          MeshNode(
            ref: ref,
            geometry: geometry,
            children: [GroupNode(ref: child)],
          ),
        ],
      ),
    );
    await tester.pumpWidget(scene(const SceneGeometry.box()));
    final old = ref.require, nested = child.require;
    old.rotateY(.5);
    final rotation = old.quaternion;
    await tester.pumpWidget(scene(const SceneGeometry.sphere(radius: .5)));
    expect(ref.require, isNot(same(old)));
    expect(old.parent, isNull);
    expect(old.children, isEmpty);
    expect(child.require, same(nested));
    expect(nested.parent, same(ref.require));
    expect(ref.require.quaternion, rotation);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });

  testWidgets(
    'keys retain identity on reorder and removal detaches only that node',
    (tester) async {
      final sceneRuntime = runtime(FakeBackend());
      final a = SceneRef<Group>(), b = SceneRef<Group>();
      late SceneController controller;
      Widget scene(List<String> names) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          onCreated: (value) => controller = value,
          children: [
            for (final name in names)
              GroupNode(
                key: ValueKey(name),
                name: name,
                ref: name == 'a' ? a : b,
              ),
          ],
        ),
      );
      await tester.pumpWidget(scene(['a', 'b']));
      final first = a.require, second = b.require;
      await tester.pumpWidget(scene(['b', 'a']));
      expect(a.require, same(first));
      expect(b.require, same(second));
      await tester.pumpWidget(scene(['b']));
      expect(a.current, isNull);
      expect(first.parent, isNull);
      expect(controller.scene.children, [second]);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'frame callbacks use latest closures and stop demand on removal',
    (tester) async {
      final backend = FakeBackend();
      final sceneRuntime = runtime(backend);
      var oldCalls = 0, newCalls = 0;
      final ref = SceneRef<Mesh>();
      Widget scene(void Function(Mesh, FrameTime)? callback) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [
            MeshNode(
              ref: ref,
              geometry: const SceneGeometry.box(),
              onFrame: callback,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        scene((mesh, time) {
          oldCalls++;
          mesh.rotateY(time.deltaSeconds);
        }),
      );
      await frames(tester);
      expect(oldCalls, greaterThan(0));
      final previousCalls = oldCalls;
      final rotation = ref.require.quaternion;
      await tester.pumpWidget(
        scene((mesh, time) {
          newCalls++;
          mesh.rotateY(time.deltaSeconds);
        }),
      );
      await frames(tester);
      expect(oldCalls, previousCalls);
      expect(newCalls, greaterThan(0));
      expect(ref.require.quaternion, isNot(rotation));
      await tester.pumpWidget(scene(null));
      await frames(tester);
      final stoppedCalls = newCalls, submissions = backend.submissions.length;
      await frames(tester);
      expect(newCalls, stoppedCalls);
      expect(backend.submissions.length, submissions);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'tap handlers can be added, replaced and removed during rebuild',
    (tester) async {
      final sceneRuntime = runtime(FakeBackend());
      final ref = SceneRef<Mesh>();
      PickResult? picked;
      var calls = 0;
      Widget scene(void Function(PickResult)? callback) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [
            MeshNode(
              ref: ref,
              geometry: const SceneGeometry.box(),
              onTap: callback,
            ),
          ],
        ),
      );
      await tester.pumpWidget(scene(null));
      await frames(tester);
      await tester.pumpWidget(scene((hit) => picked = hit));
      await frames(tester);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      expect(picked?.object, same(ref.require));
      await tester.pumpWidget(scene((hit) => calls++));
      await frames(tester);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(scene(null));
      await frames(tester);
      await tester.tap(find.byType(SceneView));
      await tester.pump();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'borrowed objects keep children and retain replacement transforms',
    (tester) async {
      final sceneRuntime = runtime(FakeBackend());
      final first = Group()..position = const Vec3(1, 0, 0);
      final second = Group()..position = const Vec3(2, 0, 0);
      final external = first.add(Group());
      final ref = SceneRef<Group>();
      Widget scene(Group object) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [ObjectNode(object: object, ref: ref)],
        ),
      );
      await tester.pumpWidget(scene(first));
      expect(ref.require, same(first));
      await tester.pumpWidget(scene(second));
      expect(first.parent, isNull);
      expect(first.children, [external]);
      expect(second.position, const Vec3(2, 0, 0));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(second.parent, isNull);
      expect(ref.current, isNull);
    },
  );

  testWidgets('composed components and overlays share the canvas scope', (
    tester,
  ) async {
    final sceneRuntime = runtime(FakeBackend());
    final ref = SceneRef<Mesh>();
    SceneController? fromNode, fromOverlay;
    await tester.pumpWidget(
      host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [
            Builder(
              builder: (context) {
                fromNode = SceneScope.of(context);
                return MeshNode(ref: ref, geometry: const SceneGeometry.box());
              },
            ),
          ],
          overlay: Builder(
            builder: (context) {
              fromOverlay = SceneScope.of(context);
              return const Align(
                alignment: Alignment.topLeft,
                child: Text('Overlay'),
              );
            },
          ),
        ),
      ),
    );
    expect(fromNode, same(fromOverlay));
    expect(fromNode!.scene.children, [ref.require]);
    expect(find.text('Overlay'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });

  testWidgets('SceneFrame can pause and camera descriptions can change', (
    tester,
  ) async {
    final sceneRuntime = runtime(FakeBackend());
    late SceneController controller;
    var calls = 0;
    Widget scene(bool enabled, SceneCamera camera) => host(
      SceneCanvas(
        runtime: sceneRuntime,
        options: readback,
        camera: camera,
        onCreated: (value) => controller = value,
        children: [SceneFrame(enabled: enabled, onFrame: (_, time) => calls++)],
      ),
    );
    await tester.pumpWidget(scene(true, const SceneCamera.perspective()));
    await frames(tester);
    expect(calls, greaterThan(0));
    await tester.pumpWidget(
      scene(false, const SceneCamera.orthographic(verticalSize: 6)),
    );
    await frames(tester);
    final paused = calls;
    expect(controller.camera, isA<OrthographicCamera>());
    await frames(tester);
    expect(calls, paused);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });

  testWidgets('missing canvas gives an actionable error', (tester) async {
    await tester.pumpWidget(const GroupNode());
    expect(tester.takeException().toString(), contains('SceneCanvas ancestor'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'duplicate borrowed object is rejected without stealing the first',
    (tester) async {
      final object = Group();
      await tester.pumpWidget(
        host(
          SceneCanvas(
            runtime: runtime(FakeBackend()),
            options: readback,
            children: [
              ObjectNode(object: object),
              ObjectNode(object: object),
            ],
          ),
        ),
      );
      expect(
        tester.takeException().toString(),
        contains('already belongs to a scene'),
      );
      expect(object.parent, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(object.parent, isNull);
    },
  );
  testWidgets(
    'GlobalKey moves a live subtree between groups without duplicating it',
    (tester) async {
      final sceneRuntime = runtime(FakeBackend());
      final key = GlobalKey();
      final ref = SceneRef<Mesh>();
      final left = SceneRef<Group>(), right = SceneRef<Group>();
      var calls = 0;
      Widget scene(bool onLeft) {
        final node = SceneFrame(
          key: key,
          onFrame: (_, time) => calls++,
          child: MeshNode(ref: ref, geometry: const SceneGeometry.box()),
        );
        return host(
          SceneCanvas(
            runtime: sceneRuntime,
            options: readback,
            children: [
              GroupNode(ref: left, children: [if (onLeft) node]),
              GroupNode(ref: right, children: [if (!onLeft) node]),
            ],
          ),
        );
      }

      await tester.pumpWidget(scene(true));
      await frames(tester);
      final mesh = ref.require;
      final before = calls;
      expect(mesh.parent, same(left.require));
      await tester.pumpWidget(scene(false));
      await frames(tester);
      expect(ref.require, same(mesh));
      expect(left.require.children, isEmpty);
      expect(right.require.children, [mesh]);
      expect(calls, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(ref.current, isNull);
    },
  );

  testWidgets('duplicate refs fail without clearing the surviving owner', (
    tester,
  ) async {
    final ref = SceneRef<Group>();
    await tester.pumpWidget(
      host(
        SceneCanvas(
          runtime: runtime(FakeBackend()),
          options: readback,
          children: [
            GroupNode(name: 'first', ref: ref),
            GroupNode(name: 'second', ref: ref),
          ],
        ),
      ),
    );
    expect(tester.takeException().toString(), contains('two scene nodes'));
    expect(ref.require.name, 'first');
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(ref.current, isNull);
  });

  testWidgets(
    'setup failures release the controller without corrupting the tree',
    (tester) async {
      late SceneController controller;
      await tester.pumpWidget(
        host(
          SceneCanvas(
            options: readback,
            runtime: runtime(FakeBackend()),
            onCreated: (value) {
              controller = value;
              throw StateError('setup fixture');
            },
          ),
        ),
      );
      expect(tester.takeException().toString(), contains('setup fixture'));
      await frames(tester);
      await controller.whenDisposed;
      expect(controller.isDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('corrected geometry recovers on rebuild without a new key', (
    tester,
  ) async {
    final sceneRuntime = runtime(FakeBackend());
    final ref = SceneRef<Mesh>();
    Widget scene(double width) => host(
      SceneCanvas(
        runtime: sceneRuntime,
        options: readback,
        children: [
          MeshNode(
            ref: ref,
            geometry: SceneGeometry.box(width: width),
          ),
        ],
      ),
    );
    await tester.pumpWidget(scene(-1));
    expect(tester.takeException(), isArgumentError);
    expect(ref.current, isNull);
    await tester.pumpWidget(scene(1));
    expect(ref.current, isNotNull);
    await tester.pumpWidget(scene(-2));
    expect(tester.takeException(), isArgumentError);
    expect(ref.current, isNull);
    await tester.pumpWidget(scene(2));
    expect(ref.current, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
}
