import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/camera_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native readback shows the ECEF calibration axes and changes pose',
    (tester) async {
      await tester.pumpWidget(const CameraLabApp());
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      Future<ui.Image> waitForImage([ui.Image? previous]) async {
        for (var i = 0; i < 240; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          final images = tester.widgetList<RawImage>(find.byType(RawImage));
          for (final widget in images) {
            final image = widget.image;
            if (image != null && !identical(image, previous)) return image;
          }
        }
        throw StateError('Native GPU did not publish a new image');
      }

      final image = await waitForImage();
      final ready = await controller.ready;
      expect(ready.presentationPath, PresentationPath.readback);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      var red = 0, green = 0, blue = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
        if (r > g * 1.5 && r > b * 1.5 && r > 100) red++;
        if (g > r * 1.5 && g > b * 1.5 && g > 100) green++;
        if (b > r * 1.5 && b > g * 1.5 && b > 100) blue++;
      }
      expect(red, greaterThan(5));
      expect(green, greaterThan(5));
      expect(blue, greaterThan(5));
      await tester.tap(find.text('Orthographic'));
      final orthographic = await waitForImage(image);
      expect(controller.camera, isA<OrthographicCamera>());
      final orthographicBytes = (await orthographic.toByteData())!.buffer
          .asUint8List();
      var orthoRed = 0, orthoGreen = 0, orthoBlue = 0;
      for (var i = 0; i < orthographicBytes.length; i += 4) {
        final r = orthographicBytes[i],
            g = orthographicBytes[i + 1],
            b = orthographicBytes[i + 2];
        if (r > g * 1.5 && r > b * 1.5 && r > 100) orthoRed++;
        if (g > r * 1.5 && g > b * 1.5 && g > 100) orthoGreen++;
        if (b > r * 1.5 && b > g * 1.5 && b > 100) orthoBlue++;
      }
      expect(orthoRed, greaterThan(5));
      expect(orthoGreen, greaterThan(5));
      expect(orthoBlue, greaterThan(5));
      expect(orthographicBytes, isNot(orderedEquals(bytes)));
      await tester.tap(find.text('Fuji pose'));
      await waitForImage(orthographic);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      debugPrint(
        'Native calibration pixel counts: red=$red green=$green blue=$blue',
      );
      debugPrint(
        'Orthographic pixels: red=$orthoRed green=$orthoGreen blue=$orthoBlue',
      );
    },
  );
}
