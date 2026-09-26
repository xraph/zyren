import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, host, readback, runtime;

void main() {
  testWidgets('borrowed remount waits for an old in-flight frame', (
    tester,
  ) async {
    final backend = FakeBackend()..frameGate = Completer<void>();
    final controller = SceneController(
      options: readback,
      runtime: runtime(backend),
    );
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(SceneView(controller: controller)));
    await frames(tester);
    expect(controller.status.value, isNot(isA<SceneFailed>()));
    expect(backend.submissions, hasLength(1));
    backend.frameGate!.complete();
    backend.frameGate = null;
    await frames(tester);
    expect(controller.status.value, isA<SceneReady>());
    expect(backend.submissions, hasLength(2));
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'borrowed unmount preserves scene and remount reuses the session',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      final mesh = controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(controller.isDisposed, isFalse);
      expect(backend.closeCount, 0);
      mesh.position = const Vec3(3, 0, 0);
      final count = backend.submissions.length;
      await tester.pumpWidget(host(SceneView(controller: controller)));
      await frames(tester);
      expect(backend.submissions.length, greaterThan(count));
      expect(mesh.position.x, 3);
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      expect(backend.closeCount, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a second simultaneous attachment fails without detaching the first',
    (tester) async {
      final backend = FakeBackend();
      final controller = SceneController(
        options: readback,
        runtime: runtime(backend),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: SceneView(controller: controller),
              ),
              SizedBox(
                width: 64,
                height: 64,
                child: SceneView(
                  controller: controller,
                  errorBuilder: (_, issue, retry) => Text(issue.code),
                ),
              ),
            ],
          ),
        ),
      );
      await frames(tester);
      expect(find.text('controllerAlreadyAttached'), findsOneWidget);
      expect(backend.submissions, hasLength(1));
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await tester.pumpWidget(const SizedBox());
    },
  );
}
