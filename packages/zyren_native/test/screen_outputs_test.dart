import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'screen stages write depth-derived auxiliary textures before consumers',
    () async {
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final owner = GpuScope.fromBackend(backend),
          compiler = GpuScope.fromBackend(backend);
      final image = await owner.resources.createTexture(
        TextureDescriptor(
          width: 32,
          height: 32,
          format: TextureFormat.rgba8Unorm,
          usage: {
            TextureUsage.sampled,
            TextureUsage.storage,
            TextureUsage.copySource,
          },
        ),
      );
      final retained = await compiler.resources.retain(image);
      final producer = await compiler.materials.compileEffect(
        PostProcessDescriptor(
          program: await compiler.shaders.compile(
            ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@group(1) @binding(0) var auxiliary:texture_storage_2d<rgba8unorm,write>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let p=vec2<i32>(v.position.xy);let depth=textureLoad(sceneDepth,p,0);
 let covered=!sceneDepthIsBackground(depth);
 textureStore(auxiliary,p,select(vec4<f32>(0.,1.,0.,1.),vec4<f32>(1.,0.,0.,1.),covered));
 return textureLoad(sceneColor,p,0);
}
'''),
          ),
          bindings: ShaderBindings([
            TextureBinding.storage(0, retained, group: 1),
          ]),
        ),
      );
      final consumer = await compiler.materials.compileEffect(
        PostProcessDescriptor(
          program: await compiler.shaders.compile(
            ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@group(1) @binding(0) var auxiliary:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 return textureLoad(auxiliary,vec2<i32>(v.position.xy),0);
}
'''),
          ),
          bindings: ShaderBindings([
            TextureBinding.sampled(0, retained, group: 1),
          ]),
        ),
      );
      await owner.close();
      final scene = Scene()
        ..add(Mesh(PlaneGeometry(width: 1, height: 1), UnlitMaterial()));
      scene.addEffect(consumer);
      scene.addEffect(producer, order: -1);
      final camera = PerspectiveCamera();
      try {
        for (final strategy in DepthStrategy.values) {
          camera.depthStrategy = strategy;
          final frame =
              await view.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(32, 32),
                    ),
                  )
                  as ReadbackOutput;
          expect(frame.image.pixels.sublist(0, 4), [0, 255, 0, 255]);
          expect(
            frame.image.pixels.sublist(
              (16 * 32 + 16) * 4,
              (16 * 32 + 16) * 4 + 4,
            ),
            [255, 0, 0, 255],
          );
        }
        final readback = await compiler.resources.readTexture(retained);
        expect(readback.sublist(0, 4), [0, 255, 0, 255]);
        await view.close();
        expect((await backend.resourceStats()).residentBytes, 32 * 32 * 4);
      } finally {
        await view.close();
        await compiler.close();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
