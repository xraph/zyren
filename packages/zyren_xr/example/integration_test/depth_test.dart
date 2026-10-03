import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren/zyren.dart' as z;
import 'package:zyren_xr/flutter.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native depth presentation and stale lease recovery', (
    tester,
  ) async {
    Future<T> native<T>(Future<T> Function() action) async {
      Object? failure;
      StackTrace? trace;
      final result = await tester.runAsync(() async {
        try {
          return await action();
        } catch (error, stack) {
          failure = error;
          trace = stack;
          debugPrint('XR native failure: $error');
          return null;
        }
      });
      if (failure != null) Error.throwWithStackTrace(failure!, trace!);
      return result as T;
    }

    const transport = MethodChannelXrTransport();
    final session = await native(() => XrSession.create(transport));
    XrPresentationController? presenter;
    try {
      await native<void>(
        () => session.start(
          configuration: const XrConfiguration(
            requireCameraPresentation: true,
            requireDepthOcclusion: true,
          ),
        ),
      );
      final p = await native(
        () => XrPresentationController.create(session: session),
      );
      presenter = p;
      final capabilities = await native(
        () => XrSession.capabilities(transport),
      );
      expect(capabilities.depthOcclusion, isTrue);
      final scene = z.Scene()
        ..background = null
        ..backgroundOpacity = 0
        ..add(
          z.Mesh(
            z.BoxGeometry(width: .15, height: .15, depth: .15),
            z.UnlitMaterial(color: const z.Color3(1, .4, .1)),
          )..position = const z.Vec3(0, 0, -.75),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: XrCameraView(controller: p)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await native<void>(() async {
        Future<T> retry<T>(Future<T> Function() action) async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (true) {
            try {
              return await action();
            } on XrException catch (error) {
              if (!{
                    'trackingUnavailable',
                    'frameDeferred',
                    'depthUnavailable',
                    'staleDepth',
                  }.contains(error.code) ||
                  DateTime.now().isAfter(deadline)) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
        }

        Future<XrCalibration> frame() async {
          final calibration = await retry(() => p.render(scene));
          expect(calibration.depthEnabled, isTrue);
          expect(calibration.depthTimestamp, calibration.timestamp);
          expect(p.diagnostics?['cameraReadbackBytes'], 0);
          expect(p.diagnostics?['nativeReadbackBytes'], 0);
          expect(p.diagnostics?['heldCameraFrames'], 0);
          if (capabilities.platform == 'arcore') {
            expect(p.diagnostics?['depthUploadBytes'], greaterThan(0));
            expect(p.diagnostics?['depthConfidenceMinimum'], 128);
          }
          return calibration;
        }

        for (var i = 0; i < 16; i++) {
          await frame();
          await Future<void>.delayed(const Duration(milliseconds: 33));
        }
        debugPrint(
          'XR_NATIVE_DEPTH_PRESENTATION_PASS ${jsonEncode({'platform': capabilities.platform, 'frames': 16, 'diagnostics': p.diagnostics})}',
        );
        final retained =
            await retry(
                  () => transport.invoke('acquireFrame', {
                    'sessionId': session.id,
                    'presenterId': p.presenterId,
                    'near': .01,
                    'far': 1000.0,
                  }),
                )
                as Map;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        // The stale depth guard must run before scene packet decoding.
        await expectLater(
          transport.invoke('presentFrame', {
            'sessionId': session.id,
            'presenterId': p.presenterId,
            'frameId': retained['frameId'],
            'revision': retained['revision'],
            'packet': Uint8List(0),
          }),
          throwsA(
            isA<XrException>().having((e) => e.code, 'code', 'staleDepth'),
          ),
        );
        final recovered = await frame();
        expect(recovered.frameId, greaterThan(retained['frameId'] as int));
        debugPrint('XR_NATIVE_DEPTH_STALE_RECOVERY_PASS');
      });
    } finally {
      await native<void>(() async {
        try {
          try {
            await presenter?.close();
          } finally {
            presenter?.dispose();
          }
        } finally {
          await session.dispose();
        }
      });
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
