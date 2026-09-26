import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'support/backend_fake.dart';
import 'support/fakes.dart';

Widget host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 64, height: 64, child: child)),
);
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

const readback = EngineOptions(presentation: PresentationPolicy.readbackOnly);
SceneRuntime runtime(FakeBackend backend) => SceneRuntime(
  backendFactory: () async => backend,
  presenterFactory: () => TestPresenter('frame', backend.events),
);

void main() {
  testWidgets(
    'asynchronous plugin cancellation remains observable through whenDisposed',
    (tester) async {
      final cancellation = Completer<void>();
      final stream = StreamController<int>(onCancel: () => cancellation.future);
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      controller.use(
        TestPlugin(
          'listener',
          [],
          onAttach: (context) {
            context.scope.listen(stream.stream, (_) {});
          },
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      controller.dispose();
      final closed = expectLater(
        controller.whenDisposed,
        throwsA(
          isA<SceneException>().having(
            (error) => error.issue.code,
            'code',
            SceneIssueCodes.cleanupFailed,
          ),
        ),
      );
      await frames(tester);
      expect(backend.closeCount, 0);
      cancellation.completeError(StateError('subscription cleanup failed'));
      await frames(tester);
      await closed;
      expect(backend.closeCount, 1);
      await tester.pumpWidget(const SizedBox());
      addTearDown(stream.close);
    },
  );

  testWidgets(
    'dispose cancels scoped plugin and update registrations during attach',
    (tester) async {
      final finish = Completer<void>();
      var releases = 0;
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      final update = controller.onUpdate((_) {});
      controller.use(
        TestPlugin(
          'pending',
          [],
          onAttach: (context) async {
            context.scope.keep(Registration(() => releases++));
            await finish.future;
          },
        ),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      controller.dispose();
      expect(releases, 1);
      expect(update.isDisposed, isTrue);
      expect(controller.assets.isClosed, isTrue);
      finish.complete();
      await frames(tester);
      await controller.whenDisposed;
      expect(backend.closeCount, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late backend cleanup failures settle disposal with a typed issue',
    (tester) async {
      final pending = Completer<RenderBackend>();
      final backend = FakeBackend()..failClose = true;
      final controller = SceneController(
        options: readback,
        runtime: SceneRuntime(backendFactory: () => pending.future),
      );
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await tester.pump();
      controller.dispose();
      final disposed = expectLater(
        controller.whenDisposed,
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            'cleanupFailed',
          ),
        ),
      );
      pending.complete(backend);
      await frames(tester);
      await disposed;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('disposal settles readiness and closes a late backend once', (
    tester,
  ) async {
    final pending = Completer<RenderBackend>();
    final backend = FakeBackend();
    final controller = SceneController(
      options: readback,
      runtime: SceneRuntime(backendFactory: () => pending.future),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await tester.pump();
    final ready = expectLater(
      controller.ready,
      throwsA(
        isA<SceneException>().having((e) => e.issue.code, 'code', 'disposed'),
      ),
    );
    controller.dispose();
    controller.dispose();
    expect(() => controller.invalidate(), throwsStateError);
    pending.complete(backend);
    await tester.pump();
    await ready;
    await controller.whenDisposed;
    expect(backend.closeCount, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'idle scenes wake on edits and retain changes during a slow frame',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      final mesh = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(backend.submissions, hasLength(1));
      await frames(tester);
      expect(backend.submissions, hasLength(1));
      backend.frameGate = Completer<void>();
      mesh.position = const Vec3(1, 0, 0);
      await frames(tester);
      mesh.position = const Vec3(2, 0, 0);
      await frames(tester);
      expect(backend.submissions, hasLength(2));
      backend.frameGate!.complete();
      backend.frameGate = null;
      await frames(tester);
      expect(backend.submissions, hasLength(3));
      final model =
          ((backend.submissions.last.toNativePacket()['meshes'] as List).single
                  as Map)['model']
              as List;
      expect(model[12], 2);
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('zero-size does not allocate and inactive windows still render', (
    tester,
  ) async {
    final backend = FakeBackend();
    var creates = 0;
    final controller = SceneController(
      options: readback,
      runtime: SceneRuntime(
        backendFactory: () async {
          creates++;
          return backend;
        },
        presenterFactory: () => TestPresenter('frame', []),
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.shrink(child: SceneView(controller: controller)),
        ),
      ),
    );
    await frames(tester);
    expect(creates, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    expect(creates, 1);
    expect(backend.submissions, hasLength(1));
    final deltas = <Duration>[];
    final registration = controller.onUpdate((time) => deltas.add(time.delta));
    await frames(tester);
    expect(deltas, isNotEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    final count = backend.submissions.length;
    await frames(tester);
    expect(backend.submissions.length, count);
    final resumeIndex = deltas.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(deltas[resumeIndex], Duration.zero);
    registration.dispose();
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });
}
