import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren/zyren.dart' as z;
import 'package:zyren_xr/flutter.dart';

// The host backgrounds and resumes the probe after XR_LIFECYCLE_BACKGROUND_READY.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'background revokes retained camera and requires explicit restart',
    (tester) async {
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
      final observer = _LifecycleProbe();
      WidgetsBinding.instance.addObserver(observer);
      try {
        await native<void>(
          () => session.start(
            configuration: const XrConfiguration(
              requireCameraPresentation: true,
            ),
          ),
        );
        final p = await native(
          () => XrPresentationController.create(session: session),
        );
        presenter = p;
        final scene = z.Scene()
          ..background = null
          ..backgroundOpacity = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: XrCameraView(controller: p)),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await native<void>(() async {
          Future<XrCalibration> frame() async {
            final deadline = DateTime.now().add(const Duration(seconds: 45));
            while (true) {
              try {
                return await p.render(scene);
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

          final before = await frame();
          final retained =
              await transport.invoke('acquireFrame', {
                    'sessionId': session.id,
                    'presenterId': p.presenterId,
                    'near': .01,
                    'far': 1000.0,
                  })
                  as Map;
          observer.arm();
          debugPrint('XR_LIFECYCLE_BACKGROUND_READY');
          await observer.backgrounded.future.timeout(
            const Duration(seconds: 45),
          );
          await observer.resumed.future.timeout(const Duration(seconds: 45));
          final paused = await session.snapshot();
          expect(paused.state, XrSessionState.paused);
          expect(paused.frame, isNull);
          await expectLater(
            transport.invoke('presentFrame', {
              'sessionId': session.id,
              'presenterId': p.presenterId,
              'frameId': retained['frameId'],
              'revision': retained['revision'],
              'packet': Uint8List(0),
            }),
            throwsA(
              isA<XrException>().having((e) => e.code, 'code', 'frameDeferred'),
            ),
          );
          await session.start(
            configuration: const XrConfiguration(
              requireCameraPresentation: true,
            ),
          );
          final after = await frame();
          expect(after.epoch, greaterThan(before.epoch));
          expect(p.diagnostics?['cameraReadbackBytes'], 0);
          expect(p.diagnostics?['nativeReadbackBytes'], 0);
          expect(p.diagnostics?['heldCameraFrames'], 0);
          debugPrint('XR_LIFECYCLE_RETAINED_FRAME_RESTART_PASS');
        });
      } finally {
        WidgetsBinding.instance.removeObserver(observer);
        await native<void>(() async {
          try {
            await presenter?.close();
          } finally {
            presenter?.dispose();
            await session.dispose();
          }
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _LifecycleProbe extends WidgetsBindingObserver {
  final backgrounded = Completer<void>(), resumed = Completer<void>();
  bool armed = false;
  void arm() {
    armed = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!armed) return;
    if (state == AppLifecycleState.paused && !backgrounded.isCompleted) {
      backgrounded.complete();
    }
    if (state == AppLifecycleState.resumed &&
        backgrounded.isCompleted &&
        !resumed.isCompleted) {
      resumed.complete();
    }
  }
}
