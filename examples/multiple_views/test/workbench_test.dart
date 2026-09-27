import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets(
    'workbench edits, undoes and scrubs at desktop and narrow widths',
    (tester) async {
      final backend = FakeBackend();
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(
        SceneWorkbenchApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () => TestPresenter('frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await frames(tester);
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final housing = controller.scene.children.single.children.first;
      final start = housing.position;
      await tester.tap(find.byTooltip('Move +X'));
      await frames(tester);
      expect(housing.position, start + const Vec3(.25, 0, 0));
      await tester.tap(find.byTooltip('Undo'));
      await frames(tester);
      expect(housing.position, start);
      await tester.tap(find.byTooltip('Redo'));
      await frames(tester);
      expect(housing.position, start + const Vec3(.25, 0, 0));
      await tester.tap(find.byKey(const ValueKey('part-Cover')));
      await frames(tester);
      final cover = controller.scene.children.single.children.last as Mesh;
      expect(cover.material.color, Color3.hex(0xf2bd65));
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('timeline')),
      );
      slider.onChanged!(1);
      await frames(tester);
      expect(cover.position.x, 2.4);
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      await tester.tap(find.byTooltip('Play'));
      await frames(tester);
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await frames(tester);
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(200));
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(controller.isDisposed, isTrue);
      var disposed = false;
      controller.whenDisposed.then((_) => disposed = true);
      for (var i = 0; i < 20 && !disposed; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(disposed, isTrue);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
