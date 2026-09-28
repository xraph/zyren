import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_lab/main.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

void main() {
  testWidgets(
    'effects, camera and resolution controls fit desktop and narrow widths',
    (tester) async {
      final backend = FakeBackend();
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ShaderLabApp(
          runtime: SceneRuntime(
            backendFactory: () async => backend,
            presenterFactory: () =>
                TestPresenter('native frame', backend.events),
          ),
          presentation: PresentationPolicy.readbackOnly,
          unsupported: UnsupportedEffects.bypass,
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      expect(controller.scene.children.length, 3);
      final before = controller.camera.position;
      await tester.drag(find.byType(SceneView), const Offset(40, 20));
      await tester.pump();
      expect(controller.camera.position, isNot(before));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      await tester.drag(
        find.byKey(const ValueKey('Saturation')),
        const Offset(-40, 0),
      );
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('Saturation'))).value,
        lessThan(1),
      );
      await tester.tap(find.byTooltip('Reset effects and camera'));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      for (final size in [const Size(320, 640), const Size(390, 700)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(250));
      }
      await tester.tap(find.byKey(const ValueKey('resolution')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('50%').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SceneView>(find.byType(SceneView)).resolutionScale,
        .5,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => controller.whenDisposed);
      expect(backend.closeCount, 1);
    },
  );
}
