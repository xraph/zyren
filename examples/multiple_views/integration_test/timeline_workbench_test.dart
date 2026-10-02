import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../test/support/workbench_timeline.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native mixed playback emits markers without readback', (
    tester,
  ) async {
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
    await exerciseWorkbenchTimeline(tester);
    expect(frames, isNotEmpty);
    expect(
      (await controller.ready).presentationPath,
      Platform.isAndroid
          ? PresentationPath.sharedTexture
          : PresentationPath.nativeView,
    );
    expect(frames.every((frame) => frame.readbackBytes == 0), isTrue);
    print('TIMELINE: ${frames.length} native samples, zero readback bytes');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await controller.whenDisposed;
    await subscription.cancel();
  });
}
