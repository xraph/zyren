import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'experimental Apple texture pixels and retained-cache characterization',
    (tester) async {
      const bridge = MethodChannel('zyren/surfaces');
      Future<Map<Object?, Object?>> diagnostics() async =>
          (await bridge.invokeMapMethod<Object?, Object?>('diagnostics'))!;
      final captureKey = GlobalKey();
      final controller = SceneController(
        runtime: SceneRuntime(
          backendFactory: () =>
              NativeBackend.create(experimentalAppleSurfaces: true),
        ),
      );
      controller.scene.background = const Color3(1, 0, 0);
      final stats = <FrameStats>[];
      final stream = controller.frameStats.listen(stats.add);
      final update = controller.onUpdate((_) {});
      await tester.binding.setSurfaceSize(const Size(390, 700));
      final extent = ValueNotifier<Size>(const Size(63, 47));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ValueListenableBuilder<Size>(
                valueListenable: extent,
                builder: (_, size, _) => SizedBox(
                  width: size.width,
                  height: size.height,
                  child: RepaintBoundary(
                    key: captureKey,
                    child: SceneView(controller: controller),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 80 && stats.isEmpty && controller.status.value is! SceneFailed;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.status.value, isNot(isA<SceneFailed>()));
      expect(
        (await controller.ready).presentationPath,
        PresentationPath.sharedTexture,
      );
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      await expectLater(
        bridge.invokeMethod<int>('connect', {'runtime': 0}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'runtimeMismatch',
          ),
        ),
      );
      expect(stats, isNotEmpty);
      expect(stats.map((s) => s.readbackBytes), everyElement(0));
      // The pinned Flutter cache holds IOSurfaces after its Metal import. This
      // intentionally records the blocked qualification gate, not a FPS pass.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final consumed = await diagnostics();
      expect(consumed['rasterCopies'], greaterThan(0));
      expect(consumed['liveBuffers'], 3);
      expect(consumed['readbackBytes'], 0);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (await diagnostics())['presentedFrames'],
        consumed['presentedFrames'],
      );
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      final center = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      expect(pixels.sublist(center, center + 4), [255, 0, 0, 255]);
      image.dispose();
      final id = tester.widget<Texture>(find.byType(Texture)).textureId;
      extent.value = const Size(81, 59);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, id);
      expect(tester.takeException(), isNull);
      update.dispose();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await controller.whenDisposed;
      for (var i = 0; i < 10; i++) {
        if ((await diagnostics())['liveBuffers'] == 0) break;
        await tester.pump(const Duration(milliseconds: 50));
      }
      final closed = await diagnostics();
      expect(closed['textures'], 0);
      expect(closed['liveBuffers'], Platform.isMacOS ? 3 : 0);
      debugPrint(
        'Apple qualification blocked: Flutter retained ${closed['liveBuffers']} IOSurfaces after unregister; native readback bytes: ${closed['readbackBytes']}.',
      );
      await stream.cancel();
      extent.dispose();
      await tester.binding.setSurfaceSize(null);
    },
  );
}
