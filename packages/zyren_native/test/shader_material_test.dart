import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'custom mesh shader samples scoped resources and keeps independent ownership',
    () async {
      final backend = await NativeBackend.create();
      final second = backend.createView();
      final scope = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final materials = backend.createMaterialCompiler();
      try {
        final image = await scope.createTexture(
          TextureDescriptor(
            width: 2,
            height: 2,
            format: TextureFormat.rgba8Unorm,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await scope.writeTexture(
          image,
          Uint8List.fromList(List.filled(16, 255)),
        );
        final parameters = await scope.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await scope.writeBuffer(parameters, Float32List.fromList([1, 0, 0, 1]));
        final source = ShaderSource.wgsl(
          '${ShaderMaterial.uniformsWgsl}\n${ShaderMaterial.vertexWgsl(uv: true)}\n'
          '''
@group(1) @binding(0) var image: texture_2d<f32>;
@group(1) @binding(1) var imageSampler: sampler;
@group(1) @binding(2) var<uniform> tint: vec4<f32>;
@fragment fn fragment(input: MeshVertex) -> @location(0) vec4<f32> {
  return meshColor(textureSample(image,imageSampler,input.uv0)*tint);
}
''',
        );
        final program = await shaders.compile(source);
        MeshShaderDescriptor descriptor({int tintBinding = 2}) =>
            MeshShaderDescriptor(
              program: program,
              requiresUv: true,
              bindings: ShaderBindings([
                TextureBinding.sampled(0, image, group: 1),
                SamplerBinding(1, group: 1),
                BufferBinding.uniform(tintBinding, parameters, group: 1),
              ]),
            );
        final shader = await materials.compile(descriptor());
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 2, height: 2), ShaderMaterial(shader)),
        );
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          position: const Vec3(0, 0, 3),
          near: 0,
          far: 10,
        );
        Future<List<int>> center([NativeBackend? target]) async {
          final output =
              await (target ?? backend).render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(32, 32),
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels.sublist(
            (16 * 32 + 16) * 4,
            (16 * 32 + 16) * 4 + 4,
          );
        }

        expect(await center(), [255, 0, 0, 255]);
        scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
        await expectLater(center(), throwsUnsupportedError);
        mesh.clippingEnabled = false;
        expect(await center(), [255, 0, 0, 255]);
        scene.clippingPlanes = [];
        mesh.clippingEnabled = true;
        await expectLater(
          materials.compile(descriptor(tintBinding: 3)),
          throwsA(
            isA<GraphException>().having(
              (e) => e.code,
              'code',
              GraphErrorCode.pipelineFailed,
            ),
          ),
        );
        expect((await backend.graphStats()).liveMaterials, 1);
        expect(await center(), [255, 0, 0, 255]);
        await scope.writeBuffer(parameters, Float32List.fromList([0, 1, 0, 1]));
        expect(await center(), [0, 255, 0, 255]);
        mesh.material = (mesh.material as ShaderMaterial).copyWith(
          side: MaterialSide.back,
        );
        expect(await center(), [0, 0, 0, 255]);
        mesh.scale = const Vec3(-1, 1, 1);
        mesh.material = (mesh.material as ShaderMaterial).copyWith(
          side: MaterialSide.front,
        );
        expect(await center(), [0, 255, 0, 255]);
        await scope.close();
        await shaders.close();
        expect((await backend.shaderStats()).livePrograms, 1);
        expect(await center(), [0, 255, 0, 255]);
        final borrower = second.createMaterialCompiler();
        final retained = await borrower.retain(shader);
        await materials.close();
        mesh.material = ShaderMaterial(retained);
        expect(await center(second), [0, 255, 0, 255]);
        await backend.close();
        expect(await center(second), [0, 255, 0, 255]);
        await borrower.close();
        scene.remove(mesh);
        expect(await center(second), [0, 0, 0, 255]);
        expect((await second.resourceStats()).residentBytes, 0);
        expect((await second.shaderStats()).livePrograms, 0);
        expect((await second.graphStats()).liveMaterials, 0);
      } finally {
        await backend.close();
        await second.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
