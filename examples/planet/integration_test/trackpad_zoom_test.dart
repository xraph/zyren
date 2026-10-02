import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/atmosphere_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native trackpad zoom travels from the surface to Earth orbit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(const AtmosphereLabApp());
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final android = defaultTargetPlatform == TargetPlatform.android;
    var frames = 0;
    final subscription = controller.frameStats.listen((stats) {
      expectSync(stats.readbackBytes, 0);
      expectSync(
        stats.presentationPath,
        android ? PresentationPath.sharedTexture : PresentationPath.nativeView,
      );
      frames++;
    });
    Future<void> waitFrame(int previous) async {
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('$issue');
        }
        if (frames > previous) return;
        if (i % 10 == 0) controller.invalidate();
      }
      fail('Trackpad navigation frame did not arrive');
    }

    const radius = 6378137.0;
    try {
      await waitFrame(0);
      final point = tester.getRect(find.byType(SceneView)).center;
      final pointer = TestPointer(71, PointerDeviceKind.trackpad);
      Future<void> update({Offset pan = Offset.zero, double scale = 1}) async {
        final before = frames;
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(point, pan: pan, scale: scale),
        );
        await waitFrame(before);
        final camera = controller.camera as PerspectiveCamera;
        expect(camera.position.isFinite, isTrue);
        expect(camera.target.isFinite, isTrue);
        expect(camera.position.length, greaterThan(radius));
        expect(camera.near, greaterThan(0));
        expect(camera.far, greaterThan(camera.near));
      }

      for (final horizon in [false, true]) {
        controller.camera = PerspectiveCamera(
          position: const Vec3(radius + 1500, 0, 0),
          target: horizon ? const Vec3(radius + 1500, 0, 10000) : Vec3.zero,
          up: horizon ? const Vec3(1, 0, 0) : const Vec3(0, 0, 1),
          near: 1,
          far: 1e9,
        );
        await waitFrame(frames);
        if (!horizon) {
          final initial = controller.camera.position.length;
          await tester.sendEventToBinding(pointer.panZoomStart(point));
          await update(scale: 1.5);
          final closer = controller.camera.position.length;
          expect(closer, lessThan(initial));
          await update(scale: .5);
          expect(controller.camera.position.length, greaterThan(closer));
          await tester.sendEventToBinding(pointer.panZoomEnd());
        }

        await tester.sendEventToBinding(pointer.panZoomStart(point));
        for (var step = 1; step <= 64; step++) {
          await update(pan: Offset(0, -400.0 * step));
        }
        await tester.sendEventToBinding(pointer.panZoomEnd());
        final orbital = controller.camera.position.length;
        expect(orbital, greaterThan(radius * 2));
        final forward = (controller.camera.target - controller.camera.position)
            .normalized();
        expect(
          forward.dot(-controller.camera.position.normalized()),
          greaterThan(.99),
        );
        await tester.sendEventToBinding(pointer.panZoomStart(point));
        await update(pan: const Offset(0, 400));
        expect(controller.camera.position.length, lessThan(orbital));
        expect(
          controller.camera.position.length - radius,
          greaterThan((orbital - radius) * .65),
          reason: 'Reversing scroll must use the current Earth-facing ray.',
        );
        await tester.sendEventToBinding(pointer.panZoomEnd());
        final beforePinch = controller.camera.position.length;
        await tester.sendEventToBinding(pointer.panZoomStart(point));
        await update(scale: 2);
        expect(controller.camera.position.length, lessThan(beforePinch));
        await tester.sendEventToBinding(pointer.panZoomEnd());
        debugPrint(
          'Trackpad ${horizon ? 'horizon' : 'ground'} to orbit: '
          '${(orbital - radius).round()} m altitude',
        );
      }
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      for (var step = 1; step <= 4; step++) {
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            point,
            pan: Offset(0, 24.0 * step),
            timeStamp: Duration(milliseconds: 16 * step),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await waitFrame(frames);
      final released = controller.camera.position.length;
      await tester.sendEventToBinding(
        pointer.panZoomEnd(timeStamp: const Duration(milliseconds: 64)),
      );
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final coasted = controller.camera.position.length;
      expect(coasted, lessThan(released - 1000));
      expect(coasted, greaterThan(radius));
      debugPrint(
        'Trackpad released zoom: $released to $coasted metres from center',
      );
      // A new gesture stops the tail before the layout check.
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      await tester.sendEventToBinding(pointer.panZoomEnd());
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await tester.pump();
      await waitFrame(frames);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(500));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
      await subscription.cancel();
      await tester.binding.setSurfaceSize(null);
    }
    final diagnostics = await MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    expect(diagnostics!['sessions'], 0);
    expect(diagnostics['renderers'], 0);
    expect(diagnostics[android ? 'surfaces' : 'heldDrawables'], 0);
    expect(diagnostics['retiring'], 0);
    expect(diagnostics['readbackBytes'], 0);
    debugPrint('Trackpad native cleanup: $diagnostics; samples=$frames');
  });
}
