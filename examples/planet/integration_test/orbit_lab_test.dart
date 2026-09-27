import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/orbit_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final behavior in OrbitBehavior.values) {
    final modern = behavior == OrbitBehavior.three184;
    testWidgets(
      '${behavior.name}: native orbit, pan, zoom, keys and narrow layout',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 760));
        await tester.pumpWidget(OrbitLabApp(behavior: behavior));
        final controller = tester
            .widget<SceneView>(find.byType(SceneView))
            .controller!;
        var frames = 0;
        final metal =
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS;
        final android = defaultTargetPlatform == TargetPlatform.android;
        final stats = controller.frameStats.listen((value) {
          if (metal) {
            expectSync(value.presentationPath, PresentationPath.nativeView);
            expectSync(value.readbackBytes, 0);
          } else if (android) {
            expectSync(value.presentationPath, PresentationPath.sharedTexture);
            expectSync(value.readbackBytes, 0);
          } else {
            expectSync(value.presentationPath, PresentationPath.readback);
            expectSync(value.readbackBytes, greaterThan(0));
          }
          frames++;
        });
        Future<void> waitFrame(int previous) async {
          for (var i = 0; i < 240; i++) {
            await tester.pump(const Duration(milliseconds: 25));
            if (controller.status.value case SceneFailed(:final issue)) {
              fail('$issue');
            }
            if (frames > previous) return;
          }
          fail('Native orbit frame did not arrive');
        }

        await waitFrame(0);
        await tester.tap(find.text('Damping'));
        await tester.pump();
        final original = controller.camera.position;
        final originalTarget = controller.camera.target;
        final distance = original.distanceTo(originalTarget);
        var viewport = tester.getRect(find.byType(SceneView));
        await tester.pump(const Duration(milliseconds: 250));
        var previous = frames;
        final rotate = await tester.startGesture(
          viewport.center,
          kind: PointerDeviceKind.mouse,
        );
        await rotate.moveBy(const Offset(100, -30));
        await rotate.up();
        await waitFrame(previous);
        expect(
          controller.camera.position.distanceTo(original),
          greaterThan(.5),
        );
        expect(
          controller.camera.position.distanceTo(controller.camera.target),
          closeTo(distance, 1e-8),
        );
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        final pan = await tester.startGesture(
          viewport.center,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await pan.moveBy(const Offset(50, 20));
        await pan.up();
        await waitFrame(previous);
        expect(
          controller.camera.target.distanceTo(originalTarget),
          greaterThan(.2),
        );
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: viewport.center + const Offset(60, -30),
            scrollDelta: const Offset(0, -40),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await waitFrame(previous);
        expect(
          controller.camera.position.distanceTo(controller.camera.target),
          closeTo(distance * math.pow(.95, modern ? .4 : 1), 1e-7),
        );
        final beforeKeys = controller.camera.target;
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        await tester.tapAt(viewport.center);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await waitFrame(previous);
        expect(
          controller.camera.target.distanceTo(beforeKeys),
          greaterThan(.05),
        );
        if (modern) {
          final targetBeforeRotate = controller.camera.target;
          final positionBeforeRotate = controller.camera.position;
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          expect(
            controller.camera.position.distanceTo(positionBeforeRotate),
            greaterThan(.01),
          );
          expect(
            controller.camera.target.distanceTo(targetBeforeRotate),
            lessThan(1e-8),
          );
        }
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        await tester.tap(find.text('Orthographic'));
        await waitFrame(previous);
        expect(controller.camera, isA<OrthographicCamera>());
        final orthographic = controller.camera as OrthographicCamera;
        final beforeZoom = orthographic.zoom;
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        final first = await tester.startGesture(
          viewport.center - const Offset(70, 0),
          pointer: 10,
        );
        final second = await tester.startGesture(
          viewport.center + const Offset(70, 0),
          pointer: 11,
        );
        await first.moveBy(const Offset(-30, 10));
        await second.moveBy(const Offset(30, 10));
        await first.up();
        final beforeContinuation = controller.camera.position;
        await second.moveBy(const Offset(25, -10));
        expect(
          controller.camera.position.distanceTo(beforeContinuation),
          modern ? greaterThan(.01) : lessThan(1e-8),
        );
        await second.up();
        await waitFrame(previous);
        expect(orthographic.zoom, greaterThan(beforeZoom));
        await tester.tap(find.text('Damping'));
        await tester.pump(const Duration(milliseconds: 250));
        previous = frames;
        final damped = await tester.startGesture(
          viewport.center,
          kind: PointerDeviceKind.mouse,
        );
        await damped.moveBy(const Offset(12, 4));
        await damped.up();
        await tester.pump(const Duration(milliseconds: 16));
        final beforeCursorZoom = orthographic.zoom;
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: viewport.center + const Offset(60, -30),
            scrollDelta: const Offset(0, -4),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await waitFrame(previous);
        expect(orthographic.zoom, greaterThan(beforeCursorZoom));
        await tester.binding.setSurfaceSize(const Size(390, 700));
        await tester.pump(const Duration(milliseconds: 250));
        viewport = tester.getRect(find.byType(SceneView));
        expect(
          (orthographic.right - orthographic.left) /
              (orthographic.top - orthographic.bottom),
          closeTo(viewport.width / viewport.height, 1e-12),
        );
        expect(tester.takeException(), isNull);
        if (!metal && !android) {
          final image = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .firstWhere((w) => w.image != null)
              .image!;
          final pixels = (await image.toByteData())!.buffer.asUint8List();
          var red = 0, green = 0, blue = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
            if (r > 100 && r > g * 1.5 && r > b * 1.5) red++;
            if (g > 100 && g > r * 1.5 && g > b * 1.5) green++;
            if (b > 100 && b > r * 1.5 && b > g * 1.5) blue++;
          }
          expect(red, greaterThan(20));
          expect(green, greaterThan(20));
          expect(blue, greaterThan(20));
          debugPrint('Orbit lab readback: red=$red green=$green blue=$blue');
        }
        await tester.pumpWidget(const SizedBox());
        await controller.whenDisposed;
        await stats.cancel();
        if (metal || android) {
          final diagnostics = await MethodChannel(
            android ? 'gpu3d/android-surfaces' : 'gpu3d/scene-views',
          ).invokeMapMethod<Object?, Object?>('diagnostics');
          expect(diagnostics!['sessions'], 0);
          expect(diagnostics['renderers'], 0);
          expect(diagnostics[android ? 'surfaces' : 'heldDrawables'], 0);
          expect(diagnostics['retiring'], 0);
          expect(diagnostics['readbackBytes'], 0);
          debugPrint('Orbit lab native cleanup: $diagnostics');
        }
        debugPrint('Orbit lab rendered $frames diagnostic frames');
        await tester.binding.setSurfaceSize(null);
      },
    );
  }
}
