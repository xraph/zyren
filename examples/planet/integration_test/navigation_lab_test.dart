import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/navigation_lab.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native globe navigation selection and projection transitions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    await tester.pumpWidget(const NavigationLabApp());
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
      fail('Globe navigation frame did not arrive');
    }

    await waitFrame(0);
    final initial = controller.camera.position;
    final view = find.byType(SceneView);
    var rect = tester.getRect(view);
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(find.textContaining('Selected'), findsOneWidget);
    final before = frames;
    await tester.timedDragFrom(
      rect.center,
      const Offset(45, 20),
      const Duration(milliseconds: 300),
    );
    await waitFrame(before);
    expect(controller.camera.position.distanceTo(initial), greaterThan(1000));
    await tester.tap(find.text('Orthographic'));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(controller.camera, isA<OrthographicCamera>());
    await waitFrame(frames);
    rect = tester.getRect(view);
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(find.textContaining('Selected'), findsOneWidget);
    await tester.tap(find.text('Perspective'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(controller.camera, isA<PerspectiveCamera>());
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pump(const Duration(milliseconds: 100));
    await waitFrame(frames);
    expect(tester.takeException(), isNull);
    rect = tester.getRect(view);
    expect(rect.height, greaterThan(400));
    final held = await tester.startGesture(rect.center, pointer: 41);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await waitFrame(frames);
    await held.cancel();
    await tester.tap(find.text('Reset view'));
    await waitFrame(frames);
    expect(controller.camera.position.distanceTo(initial), lessThan(1));
    await tester.pumpWidget(const SizedBox());
    await controller.whenDisposed;
    await subscription.cancel();
    final diagnostics = await MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    expect(diagnostics!['sessions'], 0);
    expect(diagnostics['renderers'], 0);
    expect(diagnostics[android ? 'surfaces' : 'heldDrawables'], 0);
    expect(diagnostics['retiring'], 0);
    expect(diagnostics['readbackBytes'], 0);
    debugPrint('Navigation native cleanup: $diagnostics; samples=$frames');
    await tester.binding.setSurfaceSize(null);
  });
}
