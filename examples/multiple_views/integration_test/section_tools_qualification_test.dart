import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../../packages/zyren_tools/test/support/cap_fixtures.dart';
import '../test/support/workbench_section.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native tools qualify contours, shader cuts and workbench controls', (
    tester,
  ) async {
    // Offscreen pixel checks intentionally read back. The mounted workbench below
    // separately verifies native presentation with zero frame readbacks.
    final backend = await NativeBackend.create();
    final shaders = backend.createShaderCompiler();
    final materials = backend.createMaterialCompiler();
    try {
      final program = await shaders.compile(
        ShaderSource.wgsl(
          '${ShaderMaterial.uniformsWgsl}\n${ShaderMaterial.vertexWgsl()}\n'
          '''
@fragment fn fragment(input: MeshVertex) -> @location(0) vec4<f32> {
  meshClip(input.relativePosition);
  return meshColor(vec4(1.,0.,0.,1.));
}
''',
        ),
      );
      final shader = await materials.compile(
        MeshShaderDescriptor(program: program, supportsClipping: true),
      );
      for (final depth in DepthStrategy.values) {
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(
          Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(shader)),
        );
        scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
        final frame =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: OrthographicCamera(
                      depthStrategy: depth,
                      left: -1,
                      right: 1,
                      top: 1,
                      bottom: -1,
                      near: .1,
                      far: 10,
                      position: const Vec3(0, 0, 3),
                    ),
                    size: PhysicalSize(33, 33),
                  ),
                )
                as ReadbackOutput;
        expect(frame.image.pixels[(16 * 33 + 8) * 4], 0);
        expect(frame.image.pixels[(16 * 33 + 24) * 4], 255);
      }
    } finally {
      await materials.close();
      await shaders.close();
      await backend.close();
    }
    for (final depth in DepthStrategy.values) {
      for (final cavity in [false, true]) {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final geometry = cavity
            ? combineCapShells([
                (BoxGeometry(width: 4, height: 4, depth: 4), Vec3.zero),
                (BoxGeometry(width: 2, height: 2, depth: 2), Vec3.zero),
              ])
            : concaveCapPrism();
        final source = scene.add(
          Mesh(
            geometry,
            UnlitMaterial(
              color: const Color3(1, 0, 0),
              side: MaterialSide.front,
            ),
          ),
        );
        final sections = SceneSectionPlugin(
          capMaterial: UnlitMaterial(color: const Color3(0, 1, 0)),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: OrthographicCamera(
            depthStrategy: depth,
            left: cavity ? -2 : 0,
            right: 2,
            bottom: cavity ? -2 : 0,
            top: 2,
            near: .1,
            far: 10,
            position: const Vec3(0, 0, 5),
          ),
          rendererFactory: NativeRenderer.create,
          plugins: [sections],
        );
        try {
          sections.setCapTargets([source]);
          sections.setPlanes([ClippingPlane(normal: const Vec3(0, 0, -1))]);
          final frame = await engine.render(
            width: 65,
            height: 65,
            elapsed: Duration.zero,
          );
          List<int> pixel(int x, int y) =>
              frame.pixels.sublist((y * 65 + x) * 4, (y * 65 + x) * 4 + 4);
          expect(pixel(cavity ? 56 : 48, cavity ? 32 : 48), [0, 255, 0, 255]);
          expect(pixel(cavity ? 32 : 48, cavity ? 32 : 16), [0, 0, 0, 255]);
        } finally {
          await engine.dispose();
        }
      }
    }
    final runtime = Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : Platform.isMacOS || Platform.isIOS
        ? const SceneRuntime.nativeMetal()
        : const SceneRuntime();
    await tester.pumpWidget(SceneWorkbenchApp(runtime: runtime));
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final frames = <FrameStats>[];
    final subscription = controller.frameStats.listen(frames.add);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await controller.whenDisposed.timeout(const Duration(seconds: 20));
      await subscription.cancel();
    });
    for (var i = 0; i < 1200; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(tester.takeException(), isNull);
      if (controller.status.value case SceneFailed(:final issue)) {
        fail(issue.message);
      }
      if (controller.status.value is SceneReady && frames.isNotEmpty) break;
    }
    expect(controller.status.value, isA<SceneReady>());
    await exerciseWorkbenchSections(tester, controller);
    expect(frames, isNotEmpty);
    expect(frames.map((frame) => frame.readbackBytes), everyElement(0));
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(240));
    debugPrint(
      'SECTION_TOOLS platform=${Platform.operatingSystem} '
      'viewport=${tester.view.physicalSize / tester.view.devicePixelRatio} '
      'frames=${frames.length} depthStrategies=2 contours=concave,cavity '
      'shaderClipping=passed capsControls=passed overlayControls=passed nativeReadbacks=0',
    );
  });
}
