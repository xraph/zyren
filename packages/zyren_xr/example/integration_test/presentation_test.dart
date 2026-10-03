import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren/zyren.dart' as z;
import 'package:zyren_xr/flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('physical calibrated camera, orientation, resize and release', (
    tester,
  ) async {
    const transport = MethodChannelXrTransport();
    Future<T> native<T>(Future<T> Function() action) async {
      Object? failure;
      StackTrace? trace;
      final value = await tester.runAsync(() async {
        try {
          return await action();
        } catch (error, stack) {
          failure = error;
          trace = stack;
          // Preserve the native code/message even when the device runner only
          // serializes FlutterErrorDetails as a stack trace.
          debugPrint('XR native failure: $error');
          return null;
        }
      });
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      return value as T;
    }

    final session = (await tester.runAsync(() => XrSession.create(transport)))!;
    XrPresentationController? controller;
    try {
      await tester.runAsync(
        () => session.start(
          configuration: const XrConfiguration(requireCameraPresentation: true),
        ),
      );
      controller = await native<XrPresentationController>(
        () => XrPresentationController.create(session: session),
      );
      final scene = z.Scene()
        ..background = null
        ..backgroundOpacity = 0
        ..add(
          z.Mesh(
            z.BoxGeometry(width: .1, height: .1, depth: .1),
            z.UnlitMaterial(color: const z.Color3(1, .4, .1)),
          )..position = const z.Vec3(0, 0, -.5),
        );
      Future<XrCalibration> frame() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (true) {
          try {
            return await controller!.render(scene);
          } on XrException catch (error) {
            if (!{
                  'trackingUnavailable',
                  'frameDeferred',
                }.contains(error.code) ||
                DateTime.now().isAfter(deadline)) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }

      for (final orientation in [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
      ]) {
        await SystemChrome.setPreferredOrientations([orientation]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: XrCameraView(controller: controller)),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        final presented = (await tester.runAsync(frame))!;
        expect(controller.presentedCalibration, same(presented));
        expect(controller.diagnostics?['nativeReadbackBytes'], 0);
        expect(controller.diagnostics?['cameraReadbackBytes'], 0);
        expect(controller.diagnostics?['inFlightLimit'], 1);
        expect(controller.diagnostics?['heldCameraFrames'], 0);
        expect(presented.pixelWidth, greaterThan(0));
        expect(presented.pixelHeight, greaterThan(0));
        if (orientation == DeviceOrientation.portraitUp) {
          expect(presented.orientation, 1);
        } else {
          expect(presented.orientation, anyOf(3, 4));
        }
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(frame);
        }
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 240,
              height: 180,
              child: XrCameraView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final resized = (await tester.runAsync(frame))!;
      expect(resized.logicalWidth, closeTo(240, 1));
      expect(resized.logicalHeight, closeTo(180, 1));
      await tester.runAsync(session.pause);
      await tester.runAsync(() async {
        await expectLater(
          controller!.render(scene),
          throwsA(isA<XrException>()),
        );
      });
      await tester.runAsync(controller.close);
      controller.dispose();
      controller = null;
    } finally {
      if (controller != null) {
        await tester.runAsync(controller.close);
        controller.dispose();
      }
      await tester.runAsync(session.dispose);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
