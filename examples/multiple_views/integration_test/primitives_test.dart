import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/primitive_checks.dart';

class PrimitiveProbe extends ScenePlugin {
  @override
  String get id => 'primitive-probe';
  final frames = <FrameStats>[];
  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) =>
      frames.add(stats);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'portable lines and points use native size and clipping',
    (tester) async => verifyPrimitives(),
  );
  testWidgets(
    'portable primitives present directly without readback or repeated upload',
    (tester) async {
      final android = Platform.isAndroid;
      final controller = SceneController(
        runtime: android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
      final line = controller.scene.add(
        Line(
          LineGeometry(points: [const Vec3(-1, 0, 0), const Vec3(1, 0, 0)]),
          LineMaterial(width: 6),
        ),
      );
      final points = controller.scene.add(
        Points(PointGeometry(points: [Vec3.zero]), PointsMaterial(size: 12)),
      );
      final probe = controller.use(PrimitiveProbe());
      Future<void> frameAfter(int count) async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (probe.frames.length > count ||
              controller.status.value is SceneFailed) {
            break;
          }
        }
        expect(controller.status.value, isA<SceneReady>());
        expect(probe.frames.length, greaterThan(count));
      }

      try {
        await tester.pumpWidget(
          MaterialApp(home: SceneView(controller: controller)),
        );
        await frameAfter(0);
        expect(
          probe.frames.last.presentationPath,
          android
              ? PresentationPath.sharedTexture
              : PresentationPath.nativeView,
        );
        for (final edit in <void Function()>[
          () => line.material = line.material.copyWith(
            width: .1,
            widthUnits: SizeUnits.world,
          ),
          () => points.material = points.material.copyWith(
            size: .2,
            sizeUnits: SizeUnits.world,
          ),
          () => points.material = points.material.copyWith(
            shape: PointShape.square,
          ),
          () => controller.camera.position = const Vec3(0, 0, 10),
          () => controller.scene.rotateY(.35),
        ]) {
          final count = probe.frames.length;
          edit();
          await frameAfter(count);
          expect(probe.frames.last.uploadedBytes, 0);
        }
        expect(
          probe.frames.map((frame) => frame.readbackBytes),
          everyElement(0),
        );
        expect(find.byType(RawImage), findsNothing);
      } finally {
        controller.dispose();
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        await controller.whenDisposed;
      }
    },
  );
}
