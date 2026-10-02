import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import 'package:zyren/rendering.dart';

import '../test/support/workbench_timeline.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('workbench uses the real native phone viewport and disposes', (
    tester,
  ) async {
    expect(Platform.isAndroid || Platform.isIOS, isTrue);
    // Keep the device's viewport. Test surface overrides would mask native size.
    final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint('QUALIFICATION viewport: $logical');
    expect(logical.width, lessThanOrEqualTo(500));
    await tester.pumpWidget(
      SceneWorkbenchApp(
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      ),
    );
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final frames = <FrameStats>[];
    final subscription = controller.frameStats.listen(frames.add);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await controller.whenDisposed.timeout(const Duration(seconds: 15));
      await subscription.cancel();
    });
    for (var i = 0; i < 1200; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(tester.takeException(), isNull);
      if (controller.status.value case SceneFailed(:final issue)) {
        fail('Native startup failed: ${issue.message}');
      }
      if (controller.status.value is SceneReady && frames.isNotEmpty) break;
    }
    expect(
      controller.status.value,
      isA<SceneReady>(),
      reason: 'Native startup after 30 seconds: ${controller.status.value}',
    );
    expect(frames, isNotEmpty);
    expect(
      (await controller.ready).presentationPath,
      Platform.isAndroid
          ? PresentationPath.sharedTexture
          : PresentationPath.nativeView,
    );
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(240));
    expect(
      tester.getSize(find.byKey(const ValueKey('timeline'))).width,
      greaterThan(64),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('part-Cover')));
    await tester.tap(find.byKey(const ValueKey('part-Cover')));
    await tester.pump(const Duration(milliseconds: 250));
    final cover = controller.scene.children.single.children.firstWhere(
      (node) => node.name == 'Cover',
    );
    expect(controller.scene.outline?.objects, contains(cover));
    await exerciseWorkbenchTimeline(tester);
    expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
    debugPrint(
      'QUALIFICATION native phone: ${frames.length} samples, '
      'selection outline, timeline and markers passed, zero readbacks.',
    );
  });
}
