import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';
import 'controller_test.dart' show frames, host, readback;

void main() {
  testWidgets(
    'managed rebuilds preserve setup and replacement waits for teardown',
    (tester) async {
      final events = <String>[];
      var setups = 0;
      final backends = <FakeBackend>[];
      Widget view(int key) => host(
        SceneView.builder(
          sceneKey: key,
          options: readback,
          runtime: SceneRuntime(
            backendFactory: () async {
              events.add('backend.create');
              final backend = FakeBackend(events);
              backends.add(backend);
              return backend;
            },
            presenterFactory: () => TestPresenter('frame', events),
          ),
          onCreate: (controller) {
            setups++;
            controller.use(TestPlugin('first', events));
            controller.use(TestPlugin('second', events));
          },
        ),
      );
      await tester.pumpWidget(view(1));
      await frames(tester);
      for (var i = 0; i < 20; i++) {
        await tester.pumpWidget(view(1));
      }
      expect(setups, 1);
      expect(backends, hasLength(1));
      await tester.pumpWidget(view(2));
      await frames(tester);
      expect(setups, 2);
      expect(backends, hasLength(2));
      expect(
        events,
        containsAllInOrder([
          'second.detach',
          'first.detach',
          'backend.close',
          'backend.create',
          'first.attach',
        ]),
      );
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(backends.map((b) => b.closeCount), everyElement(1));
    },
  );

  testWidgets(
    'onCreate failure releases registrations and shows typed failure',
    (tester) async {
      SceneController? controller;
      var creates = 0;
      await tester.pumpWidget(
        host(
          SceneView.builder(
            options: readback,
            runtime: SceneRuntime(
              backendFactory: () async {
                creates++;
                return FakeBackend();
              },
            ),
            onCreate: (view) {
              controller = view;
              view.onUpdate((_) {});
              throw StateError('setup failed');
            },
            errorBuilder: (_, issue, retry) => Text(issue.message),
          ),
        ),
      );
      await frames(tester);
      expect(find.textContaining('setup failed'), findsOneWidget);
      expect(creates, 0);
      expect(controller!.isDisposed, isTrue);
      await controller!.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retry does not replay setup or duplicate nodes', (tester) async {
    final events = <String>[];
    var setups = 0, creates = 0;
    var fail = true;
    SceneController? controller;
    final plugin = TestPlugin(
      'temporary',
      events,
      onAttach: (_) {
        if (fail) throw StateError('temporary');
      },
    );
    await tester.pumpWidget(
      host(
        SceneView.builder(
          options: readback,
          runtime: SceneRuntime(
            backendFactory: () async {
              creates++;
              return FakeBackend(events);
            },
            presenterFactory: () => TestPresenter('recovered', events),
          ),
          onCreate: (view) {
            controller = view;
            setups++;
            view.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
            view.use(plugin);
          },
          errorBuilder: (_, issue, retry) => const Text('Retry needed'),
        ),
      ),
    );
    await frames(tester);
    expect(find.text('Retry needed'), findsOneWidget);
    final oldReady = controller!.ready;
    fail = false;
    final retry = controller!.retry();
    await frames(tester);
    await retry;
    expect(controller!.ready, isNot(same(oldReady)));
    expect(setups, 1);
    expect(creates, 2);
    expect(controller!.scene.children, hasLength(1));
    expect(find.text('recovered'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
}
