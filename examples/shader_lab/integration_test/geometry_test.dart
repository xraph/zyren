import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/geometry.dart';
import '../../../packages/gpu3d_native/test/support/mesh_shader_geometry_checks.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('custom skin and instance shaders present and settle natively', (
    tester,
  ) async {
    final backend = Platform.isAndroid
        ? await NativeBackend.create()
        : await NativeMetalBackend.create();
    try {
      await verifyMeshShaderGeometry(backend);
    } finally {
      await backend.close();
    }
    await tester.pumpWidget(const GeometryLabApp(autoplay: false));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final frames = <FrameStats>[];
    final sub = controller.frameStats.listen(frames.add);
    Future<void> advance() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    try {
      final first = await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == 2,
      );
      expect(first.readbackBytes, 0);
      final mesh = controller.scene.children.whereType<InstancedMesh>().single;
      expect(
        (mesh.material as ShaderMaterial).program.geometry,
        MeshShaderGeometry.deformedInstanced,
      );
      final frozen = mesh.captureDeformation();
      tester
          .widget<Slider>(find.byKey(const ValueKey('Geometry Width')))
          .onChanged!(1);
      await advance();
      expect(mesh.captureDeformation(), isNot(same(frozen)));
      expect(frames.last.uploadedBytes, 672);
      tester
          .widget<Slider>(find.byKey(const ValueKey('Geometry Stripes')))
          .onChanged!(3);
      await advance();
      expect(
        frames.last.uploadedBytes,
        0,
        reason: 'Uniform edits retain geometry and pose resources.',
      );
      await tester.tap(find.byKey(const ValueKey('Geometry playback')));
      await advance();
      expect(frames.last.uploadedBytes, 400);
      await tester.tap(find.byKey(const ValueKey('Geometry playback')));
      await advance();
      final settled = frames.length;
      await advance();
      expect(frames.length, settled);
      expect(frames.every((f) => f.readbackBytes == 0), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await sub.cancel();
      await tester.pumpWidget(const SizedBox());
      await controller.whenDisposed;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
