import 'dart:convert';
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

    final session = await native(() => XrSession.create(transport));
    XrPresentationController? controller;
    try {
      await native<void>(
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
      Future<XrCalibration> frame({DateTime? deadline}) async {
        final expires =
            deadline ?? DateTime.now().add(const Duration(seconds: 30));
        while (true) {
          try {
            return await controller!.render(scene);
          } on XrException catch (error) {
            if (!{
                  'trackingUnavailable',
                  'frameDeferred',
                }.contains(error.code) ||
                DateTime.now().isAfter(expires)) {
              rethrow;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }

      Future<XrCalibration> frameForSize(Size size) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (true) {
          final calibration = await native(() => frame(deadline: deadline));
          if (DateTime.now().isAfter(deadline)) {
            fail('Native camera dimensions did not converge to $size.');
          }
          if ((calibration.logicalWidth - size.width).abs() <= 1 &&
              (calibration.logicalHeight - size.height).abs() <= 1) {
            return calibration;
          }
          await tester.pump(const Duration(milliseconds: 100));
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
        final portrait = orientation == DeviceOrientation.portraitUp;
        Size viewSize = tester.getSize(find.byType(XrCameraView));
        for (
          var attempt = 0;
          attempt < 150 && (viewSize.height > viewSize.width) != portrait;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          viewSize = tester.getSize(find.byType(XrCameraView));
        }
        expect(viewSize.height > viewSize.width, portrait);
        final presented = await frameForSize(viewSize);
        expect(controller.presentedCalibration, same(presented));
        expect(controller.diagnostics?['nativeReadbackBytes'], 0);
        expect(controller.diagnostics?['cameraReadbackBytes'], 0);
        expect(controller.diagnostics?['inFlightLimit'], 1);
        expect(controller.diagnostics?['heldCameraFrames'], 0);
        expect(presented.pixelWidth, greaterThan(0));
        expect(presented.pixelHeight, greaterThan(0));
        expect(presented.logicalWidth, closeTo(viewSize.width, 1));
        expect(presented.logicalHeight, closeTo(viewSize.height, 1));
        if (orientation == DeviceOrientation.portraitUp) {
          expect(presented.orientation, 1);
        } else {
          expect(presented.orientation, anyOf(3, 4));
        }
        for (var i = 0; i < 30; i++) {
          final steady = await native(frame);
          expect(steady.logicalWidth, closeTo(viewSize.width, 1));
          expect(steady.logicalHeight, closeTo(viewSize.height, 1));
          expect(steady.orientation, presented.orientation);
        }
        debugPrint(
          'XR_CAMERA_ORIENTATION_PASS ${jsonEncode({'orientation': presented.orientation, 'pixelWidth': presented.pixelWidth, 'pixelHeight': presented.pixelHeight, 'frames': 31, 'diagnostics': controller.diagnostics})}',
        );
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
      final resized = await frameForSize(const Size(240, 180));
      expect(resized.logicalWidth, closeTo(240, 1));
      expect(resized.logicalHeight, closeTo(180, 1));
      await native<void>(session.pause);
      await native<void>(() async {
        await expectLater(
          controller!.render(scene),
          throwsA(isA<XrException>()),
        );
      });
      await native<void>(controller.close);
      controller.dispose();
      controller = null;
      debugPrint('XR_CAMERA_RESIZE_PAUSE_RELEASE_PASS');
    } finally {
      try {
        if (controller != null) {
          try {
            await native<void>(controller.close);
          } finally {
            controller.dispose();
          }
        }
      } finally {
        try {
          await native<void>(session.dispose);
        } finally {
          await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
