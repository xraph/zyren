import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'display effects run after bloom and output conversion, outside HDR history',
    () async {
      final backend = await NativeBackend.create();
      final programs = backend.createShaderCompiler(),
          materials = backend.createMaterialCompiler();
      final retained = backend.createMaterialCompiler();
      try {
        Future<ScreenEffect> effect(
          String body,
          PostProcessStage stage,
        ) async => materials.compileEffect(
          PostProcessDescriptor(
            stage: stage,
            program: await programs.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {$body}',
              ),
            ),
          ),
        );
        final display = await effect(
          'let c=textureLoad(sceneColor,vec2<i32>(v.position.xy),0);return vec4<f32>(c.rgb*.5,c.a);',
          PostProcessStage.display,
        );
        final history = await effect(
          'let p=vec2<i32>(v.position.xy);let c=textureLoad(sceneColor,p,0);return vec4<f32>(c.rgb+textureLoad(historyColor,p,0).rgb*.25*screen.viewport.z,c.a);',
          PostProcessStage.hdr,
        );
        final keep = await retained.retainEffect(display);
        expect(keep.stage, PostProcessStage.display);
        final scene = Scene()
          ..background = const Color3(.25, 0, 0)
          ..renderSettings = RenderSettings(
            effects: [keep, history],
            toneMapping: ToneMapping.reinhard,
            exposure: 2,
            backgroundAlpha: .5,
            bloom: BloomSettings(threshold: 0, intensity: .5),
          );
        int srgb(double x) =>
            (255 *
                    (x <= .0031308
                        ? x * 12.92
                        : 1.055 * math.pow(x, 1 / 2.4) - .055))
                .round();
        for (var i = 0; i < 3; i++) {
          final size = i == 2 ? 17 : 16;
          final result =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(),
                      size: PhysicalSize(size, size),
                    ),
                  )
                  as ReadbackOutput;
          // Bloom is clipped by coverage before the display stage.
          final source = .25 * (i == 1 ? 1.25 : 1) * 1.25 * 2;
          expect(
            result.image.pixels[0],
            closeTo(srgb(source / (1 + source)) * .25, 1),
          );
          expect(result.image.pixels[3], closeTo(128, 1));
        }
      } finally {
        await retained.close();
        await materials.close();
        await programs.close();
        // Replacing the published cover releases its native binding references.
        await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(16, 16),
          ),
        );
        expect((await backend.graphStats()).liveMaterials, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
