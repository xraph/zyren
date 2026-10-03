import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'small screen targets preserve the scene chain and retain same-frame outputs',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend),
          textures = backend.createResourceScope();
      try {
        final target = await textures.createTexture(
          TextureDescriptor(
            width: 3,
            height: 2,
            format: TextureFormat.rgba16Float,
            usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
          ),
        );
        final producer = await owner.materials.compileEffect(
          PostProcessDescriptor(
            target: target,
            program: await owner.shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return vec4<f32>(v.uv,.5,1.);}',
              ),
            ),
          ),
        );
        final consumer = await owner.materials.compileEffect(
          PostProcessDescriptor(
            program: await owner.shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var image:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{let p=vec2<i32>(v.position.xy);let base=textureLoad(sceneColor,p,0);let c=textureLoad(image,vec2<i32>(2,1),0);return vec4<f32>(base.r,c.g,c.b,1.);}',
              ),
            ),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, target, group: 1),
            ]),
          ),
        );
        await textures.close();
        final scene = Scene()
          ..background = const Color3(.25, 0, 0)
          ..renderSettings = RenderSettings(
            effects: [...List.filled(31, producer), consumer],
          );
        expect(() => scene.addEffect(producer), throwsStateError);
        expect(
          () => RenderSettings(effects: List.filled(33, producer)),
          throwsArgumentError,
        );
        for (final size in [PhysicalSize(16, 12), PhysicalSize(19, 17)]) {
          final out =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(),
                      size: size,
                    ),
                  )
                  as ReadbackOutput;
          for (var i = 0; i < out.image.pixels.length; i += 4) {
            for (var c = 0; c < 4; c++) {
              expect(
                out.image.pixels[i + c],
                closeTo([137, 225, 188, 255][c], 1),
              );
            }
          }
        }
        await owner.close();
        // Replacing the published cover releases its native binding references.
        await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(16, 16),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await textures.close();
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
