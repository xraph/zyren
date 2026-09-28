import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:model_viewer/instancing.dart';
import '../../../packages/gpu3d_native/test/support/instancing_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('10000 instances use native presentation and bounded edits', (
    tester,
  ) async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyInstancing(backend);
      await verifyInstanceMaterials(backend);
      await verifyInstanceShadows(backend);
      await verifyInstanceBlendOrder(backend);
    } finally {
      await backend.close();
    }
    await tester.pumpWidget(
      InstancingApp(
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      ),
    );
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final frames = <FrameStats>[];
    final sub = controller.frameStats.listen(frames.add);
    Future<void> waitFrame(int start) async {
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        if (controller.status.value case SceneFailed(:final issue)) {
          fail(issue.message);
        }
        if (frames.length > start) return;
      }
      fail('Native instance frame was not presented.');
    }

    try {
      await waitFrame(0);
      expect(frames.last.drawCalls, 1);
      expect(frames.last.triangles, 120000);
      var start = frames.length;
      await tester.tap(find.byKey(const ValueKey('Move one instance')));
      await waitFrame(start);
      expect(frames.last.uploadedBytes, 112);
      start = frames.length;
      await tester.tap(find.byKey(const ValueKey('Rotate instances')));
      await waitFrame(start);
      expect(frames.last.uploadedBytes, 0);
      expect(frames.every((f) => f.readbackBytes == 0), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await sub.cancel();
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
