import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';
import 'controller_test.dart' show host, frames, readback, runtime;

void main() {
  testWidgets(
    'canvas coalesces dependencies, retains factory instances and toggles live',
    (tester) async {
      final backend = FakeBackend(), events = <String>[];
      final sceneRuntime = runtime(backend);
      final provider = TestPlugin('provider', events);
      late SceneController controller;
      var factories = 0;
      Widget canvas(bool enabled) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          plugins: enabled ? [provider] : [],
          onCreated: (c) => controller = c,
          children: [
            ScenePluginNode.create(
              enabled: enabled,
              create: () {
                factories++;
                return TestPlugin(
                  'consumer',
                  events,
                  dependencies: {'provider'},
                );
              },
            ),
          ],
        ),
      );
      await tester.pumpWidget(canvas(true));
      await frames(tester);
      expect(controller.pluginIds, ['provider', 'consumer']);
      final camera = controller.camera;
      events.clear();
      await tester.pumpWidget(canvas(true));
      await frames(tester);
      expect(factories, 1);
      expect(
        events.where((e) => e.endsWith('.attach') || e.endsWith('.detach')),
        isEmpty,
      );
      await tester.pumpWidget(canvas(false));
      await frames(tester);
      expect(controller.pluginIds, isEmpty);
      expect(events.where((e) => e.endsWith('.detach')), [
        'consumer.detach',
        'provider.detach',
      ]);
      await tester.pumpWidget(canvas(true));
      await frames(tester);
      expect(controller.pluginIds, ['provider', 'consumer']);
      expect(controller.camera, same(camera));
      expect(backend.closeCount, 0);
      expect(factories, 1);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await controller.whenDisposed;
    },
  );

  testWidgets(
    'orbit configuration and canvas bool update without a new session',
    (tester) async {
      final backend = FakeBackend();
      final sceneRuntime = runtime(backend);
      late SceneController controller;
      OrbitControls? controls;
      Widget canvas(bool enabled, double speed) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          orbitControls: enabled,
          configureOrbitControls: (value) {
            controls = value;
            value.rotateSpeed = speed;
          },
          onCreated: (c) => controller = c,
        ),
      );
      await tester.pumpWidget(canvas(true, 1));
      await frames(tester);
      final first = controls, camera = controller.camera;
      await tester.pumpWidget(canvas(true, 3));
      await frames(tester);
      expect(controls, same(first));
      expect(controls!.rotateSpeed, 3);
      await tester.pumpWidget(canvas(false, 3));
      await frames(tester);
      expect(controller.pluginIds, isEmpty);
      await tester.pumpWidget(canvas(true, 2));
      await frames(tester);
      expect(controller.pluginIds, ['zyren.orbit-controls']);
      expect(controls!.rotateSpeed, 2);
      expect(controller.camera, same(camera));
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'node orbit callbacks reconfigure existing controls on parent rebuild',
    (tester) async {
      final backend = FakeBackend();
      final sceneRuntime = runtime(backend);
      OrbitControls? controls;
      Widget canvas(double speed) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          children: [
            OrbitControlsNode(
              configure: (c) {
                controls = c;
                c.rotateSpeed = speed;
              },
            ),
          ],
        ),
      );
      await tester.pumpWidget(canvas(1));
      await frames(tester);
      final first = controls;
      await tester.pumpWidget(canvas(4));
      await frames(tester);
      expect(controls, same(first));
      expect(controls!.rotateSpeed, 4);
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'recoverable attach failure reports actual graph and retries through node',
    (tester) async {
      final backend = FakeBackend(), events = <String>[];
      final sceneRuntime = runtime(backend);
      final stable = TestPlugin('stable', events);
      var fail = true, closed = 0, callbacks = 0;
      Future<void> Function()? retry;
      final candidate = TestPlugin(
        'candidate',
        events,
        onAttach: (c) {
          c.scope.keep(Registration(() => closed++));
          if (fail) throw StateError('candidate failed');
        },
      );
      late SceneController controller;
      Widget canvas(bool add) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          onCreated: (c) => controller = c,
          plugins: [stable],
          children: [
            if (add)
              ScenePluginNode(
                plugin: candidate,
                onError: (issue, again) {
                  callbacks++;
                  retry = again;
                },
              ),
          ],
        ),
      );
      await tester.pumpWidget(canvas(false));
      await frames(tester);
      await tester.pumpWidget(canvas(true));
      await frames(tester);
      expect(controller.status.value, isA<SceneReady>());
      expect(controller.pluginIds, ['stable']);
      expect(controller.desiredPluginIds, ['stable', 'candidate']);
      expect(controller.state.value.pluginIssue, isNotNull);
      expect(closed, 1);
      expect(callbacks, 1);
      fail = false;
      final retried = retry!();
      await frames(tester);
      await retried;
      expect(controller.pluginIssue, isNull);
      expect(controller.pluginIds, ['stable', 'candidate']);
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(closed, 2);
    },
  );

  testWidgets(
    'pending frame completes before update and next frame keeps backend and camera',
    (tester) async {
      final backend = FakeBackend(), events = <String>[];
      final controller = SceneController(
        runtime: runtime(backend),
        options: readback,
      );
      controller.use(TestPlugin('old', events));
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final camera = controller.camera;
      final gate = Completer<void>();
      backend.frameGate = gate;
      controller.invalidate();
      await frames(tester);
      final before = backend.submissions.length;
      final changed = controller.setPlugins([TestPlugin('new', events)]);
      await frames(tester);
      expect(events, isNot(contains('old.detach')));
      expect(backend.submissions.length, before);
      gate.complete();
      await frames(tester);
      await changed;
      expect(controller.status.value, isA<SceneReady>());
      expect(controller.camera, same(camera));
      expect(backend.submissions.length, greaterThan(before));
      expect(backend.closeCount, 0);
      expect(
        events.indexOf('old.detach'),
        lessThan(events.indexOf('new.attach')),
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );

  testWidgets(
    'desired updates during initialization attach after creation without session restart',
    (tester) async {
      final gate = Completer<void>();
      final backend = FakeBackend(), events = <String>[];
      final controller = SceneController(
        options: readback,
        runtime: SceneRuntime(
          backendFactory: () async {
            await gate.future;
            return backend;
          },
          presenterFactory: () => TestPresenter('frame', events),
        ),
      );
      controller.use(TestPlugin('old', events));
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final changed = controller.setPlugins([TestPlugin('new', events)]);
      gate.complete();
      await frames(tester);
      await changed;
      expect(controller.pluginIds, ['new']);
      expect(controller.status.value, isA<SceneReady>());
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );

  testWidgets(
    'dispose during pending initialization observes update cancellation and closes backend',
    (tester) async {
      final gate = Completer<void>();
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: SceneRuntime(
          backendFactory: () async {
            await gate.future;
            return backend;
          },
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final changed = controller.setPlugins([TestPlugin('new', [])]);
      final cancelled = expectLater(changed, throwsStateError);
      controller.dispose();
      gate.complete();
      await frames(tester);
      await cancelled;
      await controller.whenDisposed;
      expect(backend.closeCount, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selectors isolate changes and immutable snapshots retain camera values',
    (tester) async {
      final controller = SceneController(
        runtime: runtime(FakeBackend()),
        options: readback,
      );
      var positionBuilds = 0, identityBuilds = 0, selectionBuilds = 0;
      var pluginBuilds = 0;
      Widget selector<T>(T Function(SceneState) select, VoidCallback built) =>
          SceneSelector<T>(
            controller: controller,
            select: select,
            builder: (_, value, _) {
              built();
              return const SizedBox();
            },
          );
      await tester.pumpWidget(
        host(
          Stack(
            children: [
              SceneView(controller: controller),
              selector((s) => s.cameraPosition, () => positionBuilds++),
              selector((s) => s.camera, () => identityBuilds++),
              selector((s) => s.selection, () => selectionBuilds++),
              selector((s) => s.pluginIds, () => pluginBuilds++),
            ],
          ),
        ),
      );
      await frames(tester);
      expect(controller.state.value.viewport.logicalSize, const Size(64, 64));
      expect(controller.state.value.status, isA<SceneReady>());
      expect(controller.state.value.renderer, isNotNull);
      expect(controller.state.value.frameStats, isNotNull);
      final before = controller.state.value;
      final oldPosition = before.cameraPosition;
      final initialPluginBuilds = pluginBuilds;
      final p = positionBuilds, i = identityBuilds, s = selectionBuilds;
      controller.camera.position = const Vec3(2, 3, 4);
      expect(controller.state.value.cameraPosition, const Vec3(2, 3, 4));
      await frames(tester);
      expect(positionBuilds, p + 1);
      expect(identityBuilds, i);
      expect(selectionBuilds, s);
      expect(before.cameraPosition, oldPosition);
      expect(pluginBuilds, initialPluginBuilds);
      expect(controller.state.value.pluginIds, same(before.pluginIds));
      await controller.setPlugins([TestPlugin("selected-plugin", [])]);
      await frames(tester);
      expect(pluginBuilds, initialPluginBuilds + 1);
      final group = Group();
      controller.scene.add(group);
      controller.selection = group;
      await frames(tester);
      expect(selectionBuilds, s + 1);
      controller.scene.remove(group);
      expect(controller.state.value.selection, isNull);
      await frames(tester);
      expect(selectionBuilds, s + 2);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
    },
  );

  testWidgets(
    'selector resubscribes on controller change with custom equality',
    (tester) async {
      final first = SceneController(), second = SceneController();
      var builds = 0;
      Widget selector(SceneController c) => host(
        SceneSelector<int>(
          controller: c,
          select: (s) => s.cameraPosition.x.round(),
          equals: (a, b) => a == b,
          builder: (_, value, _) {
            builds++;
            return Text('$value');
          },
        ),
      );
      await tester.pumpWidget(selector(first));
      first.camera.position = const Vec3(.2, 0, 5);
      await tester.pump();
      expect(builds, 1);
      await tester.pumpWidget(selector(second));
      final baseline = builds;
      first.camera.position = const Vec3(10, 0, 5);
      await tester.pump();
      expect(builds, baseline);
      second.camera.position = const Vec3(7, 0, 5);
      await tester.pump();
      await tester.pump();
      expect(find.text('7'), findsOneWidget);
      expect(builds, baseline + 1);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
      await frames(tester);
    },
  );
  testWidgets(
    'controller rejects awaited plugin updates during initialization hooks',
    (tester) async {
      final controller = SceneController(
        runtime: runtime(FakeBackend()),
        options: readback,
      );
      var rejected = false;
      controller.use(
        TestPlugin(
          'reentrant',
          [],
          onAttach: (_) async {
            await expectLater(controller.setPlugins([]), throwsStateError);
            rejected = true;
          },
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(rejected, isTrue);
      expect(controller.status.value, isA<SceneReady>());
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
    },
  );

  testWidgets(
    'duplicate declarative plugin ownership reports a retryable error',
    (tester) async {
      final backend = FakeBackend();
      final sceneRuntime = runtime(backend);
      final plugin = TestPlugin('unique', []);
      late SceneController controller;
      SceneIssue? issue;
      Widget canvas(bool duplicate) => host(
        SceneCanvas(
          runtime: sceneRuntime,
          options: readback,
          plugins: [plugin],
          onCreated: (c) => controller = c,
          onError: (value) => issue = value,
          children: [if (duplicate) ScenePluginNode(plugin: plugin)],
        ),
      );
      await tester.pumpWidget(canvas(false));
      await frames(tester);
      await tester.pumpWidget(canvas(true));
      await frames(tester);
      expect(issue!.message, contains('unique'));
      expect(controller.pluginIds, ['unique']);
      expect(controller.status.value, isA<SceneReady>());
      await tester.pumpWidget(canvas(false));
      await frames(tester);
      expect(controller.pluginIssue, isNull);
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );

  testWidgets(
    'pickAll freezes scene and camera before asynchronous hit delivery',
    (tester) async {
      final controller = SceneController(
        runtime: runtime(FakeBackend()),
        options: readback,
      );
      final front = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final back = controller.scene.add(
        Mesh(BoxGeometry(), UnlitMaterial())..position = const Vec3(0, 0, -2),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final state = controller.state.value;
      expect(controller.state.value, same(state));
      final snapshot = controller.capturePick(const ViewportPoint(32, 32));
      final hits = controller.pickAll(const ViewportPoint(32, 32));
      controller.scene.remove(front);
      back.position = const Vec3(100, 0, 0);
      controller.camera.position = const Vec3(50, 0, 5);
      await tester.pump();
      final captured = await hits;
      expect(captured.first.object, same(front));
      expect(captured.any((hit) => identical(hit.object, back)), isTrue);
      expect(snapshot.intersectFirst()!.object, same(front));
      await tester.pumpWidget(const SizedBox());
      expect(
        () => controller.capturePick(const ViewportPoint(32, 32)),
        throwsA(isA<SceneException>()),
      );
      controller.dispose();
      await frames(tester);
    },
  );

  testWidgets(
    'viewport selectors observe DPR and layout changes outside build',
    (tester) async {
      final controller = SceneController(
        runtime: runtime(FakeBackend()),
        options: readback,
      );
      var builds = 0;
      SceneViewport? viewport;
      Widget view(double width, double ratio) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: ratio),
          child: Center(
            child: SizedBox(
              width: width,
              height: 48,
              child: Stack(
                children: [
                  SceneView(controller: controller),
                  SceneSelector<SceneViewport>(
                    controller: controller,
                    select: (s) => s.viewport,
                    builder: (_, value, _) {
                      builds++;
                      viewport = value;
                      return const SizedBox();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view(48, 1));
      await frames(tester);
      final before = builds;
      await tester.pumpWidget(view(32, 2));
      await frames(tester);
      expect(viewport!.logicalSize, const Size(32, 48));
      expect(viewport!.devicePixelRatio, 2);
      expect(builds, greaterThan(before));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
    },
  );
  testWidgets(
    'a queued update retains failure until corrected initialization recovers',
    (tester) async {
      final gate = Completer<void>();
      final backend = FakeBackend();
      var attempts = 0, failRecovery = true;
      final controller = SceneController(
        options: readback,
        runtime: SceneRuntime(
          presenterFactory: () => TestPresenter('recovery', backend.events),
          backendFactory: () async {
            await gate.future;
            return attempts++ == 0 ? backend : FakeBackend();
          },
        ),
      );
      controller.use(
        TestPlugin(
          'broken',
          [],
          onAttach: (_) => throw StateError('initial attachment failed'),
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      final updated = controller.setPlugins([
        TestPlugin(
          'next',
          [],
          onAttach: (_) {
            if (failRecovery) throw StateError('replacement attachment failed');
          },
        ),
      ]);
      final failed = expectLater(updated, throwsA(isA<SceneException>()));
      gate.complete();
      await frames(tester);
      await failed;
      expect(controller.status.value, isA<SceneFailed>());
      expect(controller.pluginIssue, isNotNull);
      expect(backend.closeCount, 1);
      final initialIssue = controller.pluginIssue;
      await controller.retry();
      await frames(tester);
      expect(controller.status.value, isA<SceneFailed>());
      expect(
        (controller.status.value as SceneFailed).issue.message,
        contains('replacement attachment failed'),
      );
      expect(controller.pluginIssue, same(initialIssue));
      expect(controller.state.value.pluginIssue, same(initialIssue));
      var sawReady = false;
      SceneIssue? issueWhenReady;
      controller.status.addListener(() {
        if (controller.status.value is SceneReady) {
          sawReady = true;
          issueWhenReady = controller.pluginIssue;
        }
      });
      failRecovery = false;
      await controller.retry();
      await frames(tester);
      expect(controller.status.value, isA<SceneReady>());
      expect(sawReady, isTrue);
      expect(issueWhenReady, isNull);
      expect(controller.pluginIds, ['next']);
      expect(controller.pluginIssue, isNull);
      expect(controller.state.value.pluginIssue, isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
    },
  );
}
