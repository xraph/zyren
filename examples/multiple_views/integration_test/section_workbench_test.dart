import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import '../test/support/workbench_section.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native workbench sections render and restore without readback', (
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
    for (var i = 0; i < 200 && frames.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(controller.status.value, isNot(isA<SceneFailed>()));
    }
    expect(frames, isNotEmpty);
    for (var i = 0; i < 200; i++) {
      final section = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.content_cut),
      );
      if (section.onPressed != null) break;
      await tester.pump(const Duration(milliseconds: 25));
    }
    final initialFrames = frames.length;
    await exerciseWorkbenchSections(tester, controller);
    expect(frames.length, greaterThan(initialFrames));
    expect(frames.every((frame) => frame.readbackBytes == 0), isTrue);
    print(
      'SECTION: ${frames.length} native frames, ${frames.last.drawCalls} draws, zero readback bytes',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await controller.whenDisposed;
    await subscription.cancel();
  });
}
