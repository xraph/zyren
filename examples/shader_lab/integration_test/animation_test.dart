import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/animation.dart';
import '../../../packages/gpu3d_native/test/support/animation_checks.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native animation isolates instances and settles after pause', (
    tester,
  ) async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyAnimation(backend);
    } finally {
      await backend.close();
    }
    await tester.pumpWidget(const AnimationLabApp(autoplay: false));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    Group arm(String name) => controller.scene.children
        .whereType<Group>()
        .singleWhere((g) => g.name == name)
        .children
        .whereType<Group>()
        .single;
    Future<void> advance() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    final frames = <FrameStats>[];
    final subscription = controller.frameStats.listen(frames.add);
    try {
      final first = await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == 6,
      );
      expect(first.readbackBytes, 0);
      final leftStart = arm('Left').quaternion,
          rightStart = arm('Right').quaternion;
      await tester.tap(find.byKey(const ValueKey('Playback')));
      await advance();
      expect(arm('Left').quaternion, isNot(leftStart));
      expect(arm('Right').quaternion, rightStart);
      await tester.tap(find.byKey(const ValueKey('Playback')));
      final leftPaused = arm('Left').quaternion;
      await tester.tap(find.text('Right'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('Playback')));
      await advance();
      expect(arm('Left').quaternion, leftPaused);
      expect(arm('Right').quaternion, isNot(rightStart));
      await tester.tap(find.byKey(const ValueKey('Playback')));
      await advance();
      final count = frames.length;
      await advance();
      expect(
        frames.length,
        count,
        reason: 'No animation demand remains after both actions pause.',
      );
      await tester.drag(
        find.byKey(const ValueKey('Playhead')),
        const Offset(-40, 0),
      );
      await advance();
      expect(arm('Left').quaternion, leftPaused);
      expect(frames.last.uploadedBytes, 0);
      expect(frames.every((f) => f.readbackBytes == 0), isTrue);
      tester
          .widget<DropdownButton<int>>(
            find.byKey(const ValueKey('Repetitions')),
          )
          .onChanged!(2);
      tester
          .widget<DropdownButton<double>>(find.byKey(const ValueKey('Speed')))
          .onChanged!(2);
      await tester.tap(find.byKey(const ValueKey('Restart')));
      await tester.tap(find.byKey(const ValueKey('Playback')));
      for (var i = 0; i < 12; i++) {
        await advance();
        if (find.text('Finished · 2 runs').evaluate().isNotEmpty) break;
      }
      expect(find.text('Finished · 2 runs'), findsOneWidget);
      await advance();
      final finishedCount = frames.length;
      await advance();
      expect(
        frames.length,
        finishedCount,
        reason: 'Natural completion releases frame demand.',
      );
      expect(frames.every((f) => f.readbackBytes == 0), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await subscription.cancel();
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
