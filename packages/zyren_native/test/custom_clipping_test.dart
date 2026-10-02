import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy custom clipping uses camera-relative planes and transforms',
      () async {
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
  return meshColor(vec4(1., 0., 0., 1.));
}
''',
            ),
          );
          final shader = await materials.compile(
            MeshShaderDescriptor(program: program, supportsClipping: true),
          );
          final scene = Scene()..background = const Color3(0, 0, 0);
          final parent = scene.add(
            Group()..position = const Vec3(1000000000, 0, 0),
          );
          parent.add(
            Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(shader))
              ..scale = const Vec3(-1, 1, 1),
          );
          final camera = OrthographicCamera(
            depthStrategy: strategy,
            left: -1,
            right: 1,
            top: 1,
            bottom: -1,
            near: .1,
            far: 10,
            position: const Vec3(1000000000, 0, 3),
            target: const Vec3(1000000000, 0, 0),
          );
          scene.clippingPlanes = [
            ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1000000000),
            ClippingPlane(normal: const Vec3(0, 1, 0)),
          ];
          final frame =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(33, 33),
                    ),
                  )
                  as ReadbackOutput;
          List<int> pixel(int x, int y) => frame.image.pixels.sublist(
            (y * 33 + x) * 4,
            (y * 33 + x) * 4 + 4,
          );
          expect(pixel(8, 8), [0, 0, 0, 255]);
          expect(pixel(24, 8), [255, 0, 0, 255]);
          expect(pixel(24, 24), [0, 0, 0, 255]);
        } finally {
          await materials.close();
          await shaders.close();
          await backend.close();
        }
      },
      skip: !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
