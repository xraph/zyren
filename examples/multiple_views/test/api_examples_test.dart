import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:multiple_views/managed_mesh.dart';
import 'package:multiple_views/borrowed_viewer.dart';
import 'package:multiple_views/main.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Widget host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 100, height: 100, child: child)),
);
SceneRuntime runtime(FakeBackend backend) => SceneRuntime(
  backendFactory: () async => backend,
  presenterFactory: () => TestPresenter('frame', backend.events),
);

void main() {
  testWidgets(
    'managed example owns one session through rebuilds and teardown',
    (tester) async {
      final backend = FakeBackend();
      final environment = runtime(backend);
      await tester.pumpWidget(host(ManagedMesh(runtime: environment)));
      await frames(tester);
      expect(backend.submissions.last.scene.drawCalls, 1);
      for (var i = 0; i < 4; i++) {
        await tester.pumpWidget(host(ManagedMesh(runtime: environment)));
      }
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(backend.closeCount, 1);
    },
  );
  testWidgets('borrowed example survives unmount and reattaches', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = SceneController(
      runtime: runtime(backend),
      options: const EngineOptions(
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    await tester.pumpWidget(host(BorrowedViewer(controller: controller)));
    await frames(tester);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(backend.closeCount, 0);
    await tester.pumpWidget(host(BorrowedViewer(controller: controller)));
    await frames(tester);
    expect(backend.submissions.length, greaterThan(1));
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
    expect(backend.closeCount, 1);
  });
  testWidgets('shared scene keeps cameras and renderer ownership independent', (
    tester,
  ) async {
    final backends = <FakeBackend>[];
    await tester.pumpWidget(
      MultipleViewsApp(
        runtime: SceneRuntime(
          backendFactory: () async {
            final backend = FakeBackend();
            backends.add(backend);
            return backend;
          },
          presenterFactory: () => TestPresenter('frame', []),
        ),
      ),
    );
    await frames(tester);
    expect(backends, hasLength(2));
    final controllers = tester
        .widgetList<SceneView>(find.byType(SceneView))
        .map((w) => w.controller!)
        .toList();
    expect(controllers.first.scene, same(controllers.last.scene));
    expect(controllers.first.camera, isNot(same(controllers.last.camera)));
    final rightPosition = controllers.last.camera.position;
    final rightFrames = backends.last.submissions.length;
    await tester.tap(find.text('Move left camera'));
    await frames(tester);
    expect(controllers.last.camera.position, rightPosition);
    expect(backends.last.submissions.length, rightFrames);
    await tester.tap(find.text('Close left view'));
    await frames(tester);
    await controllers.first.whenDisposed;
    expect(backends.first.closeCount, 1);
    expect(backends.last.closeCount, 0);
    final remainingFrames = backends.last.submissions.length;
    await tester.tap(find.text('Turn mesh'));
    await frames(tester);
    expect(backends.last.submissions.length, greaterThan(remainingFrames));
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await frames(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controllers.last.whenDisposed;
    expect(backends.last.closeCount, 1);
    await tester.binding.setSurfaceSize(null);
  });
}
