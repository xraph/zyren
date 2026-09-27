import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/camera_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reference poses render through native Metal and fit narrow views',
    (tester) async {
      const channel = MethodChannel('gpu3d/scene-views');
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(const CameraLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      var frames = 0;
      final stats = controller.frameStats.listen((frame) {
        expectSync(frame.presentationPath, PresentationPath.nativeView);
        expectSync(frame.readbackBytes, 0);
        frames++;
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (ready()) return;
        }
        fail('No native camera frame arrived');
      }

      await waitFor(() => frames > 0);
      expect(
        (await controller.ready).presentationPath,
        PresentationPath.nativeView,
      );
      final expected = PointOfView(
        distance: 3000,
        heading: Angle.degrees(-155),
        pitch: Angle.degrees(-35),
      ).decompose(Geodetic.degrees(-73.9709, 40.7589).toEcef());
      expect(
        controller.camera.position.distanceTo(expected.position),
        lessThan(1e-8),
      );
      final previous = frames;
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Fuji pose'));
      await waitFor(() => frames > previous);
      expect(
        controller.camera.target.distanceTo(
          Geodetic.degrees(138.5973, 35.2138).toEcef(),
        ),
        lessThan(1e-8),
      );
      final beforeRoll = controller.camera.up;
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byType(Slider).last);
      await tester.drag(find.byType(Slider).last, const Offset(40, 0));
      await tester.pump();
      expect(controller.camera.up, isNot(beforeRoll));
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
      expect(find.text('Heading'), findsOneWidget);
      expect(find.text('Roll'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      await stats.cancel();
      final closed = await channel.invokeMapMethod<Object?, Object?>(
        'diagnostics',
      );
      expect(closed!['sessions'], 0);
      expect(closed['renderers'], 0);
      expect(closed['heldDrawables'], 0);
      debugPrint('Camera lab rendered $frames native frames, cleanup: $closed');
      await tester.binding.setSurfaceSize(null);
    },
  );
}
