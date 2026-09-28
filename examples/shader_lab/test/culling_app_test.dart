import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_lab/culling.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

void main() {
  testWidgets('culling controls pan the view and preserve a compact canvas', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CullingLabApp(
        runtime: SceneRuntime(
          backendFactory: () async => backend,
          presenterFactory: () => TestPresenter('culling', backend.events),
        ),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    expect(backend.submissions.last.scene.drawCalls, inInclusiveRange(1, 15));
    await tester.tap(find.byKey(const ValueKey('Culling enabled')));
    await tester.pumpAndSettle();
    expect(backend.submissions.last.scene.drawCalls, 61);
    await tester.tap(find.byKey(const ValueKey('Culling enabled')));
    tester.widget<Slider>(find.byKey(const ValueKey('Camera pan'))).onChanged!(
      20,
    );
    await tester.pumpAndSettle();
    expect(controller.camera.position.x, 20);
    expect(controller.camera.target.x, 20);
    expect(backend.submissions.last.scene.drawCalls, inInclusiveRange(1, 15));
    await tester.tap(find.byKey(const ValueKey('Culling projection')));
    await tester.pumpAndSettle();
    expect(controller.camera, isA<OrthographicCamera>());
    await tester.tap(find.byKey(const ValueKey('Frame all')));
    await tester.pumpAndSettle();
    expect(backend.submissions.last.scene.drawCalls, 61);
    await tester.tapAt(tester.getCenter(find.byType(SceneView)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Box 30 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('Frame selection')));
    await tester.pumpAndSettle();
    expect(backend.submissions.last.scene.drawCalls, lessThan(5));
    final selected = controller.scene.children.whereType<Mesh>().elementAt(30);
    expect(
      controller.camera.target,
      selected.bounds.transformed(selected.worldMatrix).center,
    );
    await tester.tap(find.byKey(const ValueKey('Culling projection')));
    await tester.pumpAndSettle();
    expect(controller.camera, isA<PerspectiveCamera>());
    expect(backend.submissions.last.scene.drawCalls, lessThan(5));
    for (final size in [
      const Size(1100, 700),
      const Size(390, 700),
      const Size(320, 640),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(450));
      expect(tester.takeException(), isNull);
    }
    tester.widget<Slider>(find.byKey(const ValueKey('Camera pan'))).onChanged!(
      20,
    );
    await tester.pumpAndSettle();
    expect(backend.submissions.last.scene.drawCalls, inInclusiveRange(1, 15));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => controller.whenDisposed);
    expect(backend.closeCount, 1);
  });
}
