import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/scene_alpha_checks.dart';
import 'effects_test.dart' show waitForFrame;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('transparent native pixels and Flutter composition', (
    tester,
  ) async {
    await verifySceneAlpha(
      providedBackend: Platform.isAndroid
          ? await NativeBackend.create()
          : await NativeMetalBackend.create(),
    );
    final controller = SceneController(
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
    );
    final boundary = GlobalKey();
    final fade = _Fade();
    controller.use(fade);
    controller.scene.background = const Color3(1, 0, 0);
    controller.scene.backgroundOpacity = .5;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 96,
              height: 96,
              child: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: Colors.white,
                  child: SceneView(controller: controller),
                ),
              ),
            ),
          ),
        ),
      );
      final first = await waitForFrame(
        tester,
        controller,
        (f) => f.drawCalls == 1,
      );
      expect(first.readbackBytes, 0);
      // Android embeds an external Flutter texture; Apple embeds a platform view,
      // which is outside Flutter's RepaintBoundary capture.
      Future<void> pixel(List<int> expected) async {
        if (!Platform.isAndroid) return;
        await tester.pump(const Duration(milliseconds: 100));
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final offset = (48 * image.width + 48) * 4;
          final actual = bytes.sublist(offset, offset + 4);
          for (var i = 0; i < 4; i++) {
            expect(
              actual[i],
              closeTo(expected[i], 3),
              reason: '$actual vs $expected',
            );
          }
        } finally {
          image.dispose();
        }
      }

      await pixel([255, 127, 127, 255]);
      fade.registration.enabled = true;
      await waitForFrame(tester, controller, (f) => f.drawCalls == 3);
      await pixel([255, 191, 191, 255]);
      controller.scene.backgroundOpacity = 1;
      await waitForFrame(tester, controller, (f) => f.drawCalls == 2);
      await pixel([255, 127, 127, 255]);
      fade.registration.enabled = false;
      controller.scene.backgroundOpacity = .5;
      controller.scene.background = null;
      await waitForFrame(tester, controller, (f) => f.drawCalls == 1);
      await pixel([255, 255, 255, 255]);
      controller.scene.background = const Color3(.25, .5, .75);
      await waitForFrame(tester, controller, (f) => f.drawCalls == 1);
      await pixel([196, 221, 240, 255]);
      controller.scene.backgroundOpacity = 1;
      await waitForFrame(tester, controller, (f) => f.drawCalls == 0);
      await pixel([137, 188, 225, 255]);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
    }
    final diagnostics = (await MethodChannel(
      Platform.isAndroid ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics'))!;
    expect(diagnostics['sessions'], 0);
    expect(diagnostics['renderers'], 0);
    expect(diagnostics[Platform.isAndroid ? 'surfaces' : 'heldDrawables'], 0);
  });
}

class _Fade extends ScenePlugin {
  @override
  String get id => 'test.surface.fade';
  late GraphRegistration registration;
  @override
  Future<void> attach(PluginContext context) async {
    final shader = await context.shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
  let color = textureLoad(source, vec2<i32>(p.xy), 0);
  return vec4(color.rgb, color.a * .5);
}
'''),
    );
    registration = context.graph.addEffect(
      name: 'fade',
      enabled: false,
      build: (frame) async {
        final output = await frame.createColorTexture();
        return GraphEffect(
          output: output,
          passes: [
            RenderPassDescriptor(
              name: 'fade',
              program: shader,
              color: ColorAttachment(output),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, frame.input),
              ]),
              reads: [frame.input],
              writes: [output],
            ),
          ],
        );
      },
    );
  }
}
