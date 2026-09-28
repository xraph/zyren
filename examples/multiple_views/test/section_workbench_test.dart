import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../../../packages/flutter_zyren/test/support/backend_fake.dart';
import '../../../packages/flutter_zyren/test/support/fakes.dart';
import 'support/workbench_section.dart';

void main() {
  testWidgets(
    'section controls cut, flip and restore at desktop and narrow widths',
    (tester) async {
      final backend = FakeBackend();
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        SceneWorkbenchApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () => TestPresenter('frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      for (final width in [1100.0, 390.0, 320.0]) {
        await tester.binding.setSurfaceSize(Size(width, 760));
        await tester.pump(const Duration(milliseconds: 40));
        await exerciseWorkbenchSections(tester, controller);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(240));
      }
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(controller.isDisposed, isTrue);
    },
  );
}
