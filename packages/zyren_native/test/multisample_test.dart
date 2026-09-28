import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'MSAA resolves fractional premultiplied edges and nearest covered depth',
    () async {
      final backend = await NativeBackend.create();
      expect(backend.capabilities.limits.sampleCounts, contains(4));
      expect(backend.capabilities.backend, isNotEmpty);
      final shaders = backend.createShaderCompiler(),
          materials = backend.createMaterialCompiler();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final mesh = scene.add(
        Mesh(
          PlaneGeometry(width: 1, height: 1),
          UnlitMaterial(color: const Color3(1, 1, 1)),
        )..rotateZ(.35),
      );
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<ReadbackOutput> render([int size = 32]) async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(size, size),
                ),
              )
              as ReadbackOutput;
      try {
        scene.renderSettings = RenderSettings(backgroundAlpha: 0, hdr: true);
        final single = await render();
        expect(
          {
            for (var i = 3; i < single.image.pixels.length; i += 4)
              single.image.pixels[i],
          },
          {0, 255},
        );
        scene.renderSettings = RenderSettings(
          backgroundAlpha: 0,
          sampleCount: 4,
        );
        final multisample = await render();
        final bytes = multisample.image.pixels;
        final partial = [
          for (var i = 3; i < bytes.length; i += 4)
            if (bytes[i] > 0 && bytes[i] < 255) i,
        ];
        expect(partial, isNotEmpty);
        for (final i in partial) {
          for (var c = 1; c <= 3; c++) {
            expect(bytes[i - c], closeTo(bytes[i], 1));
          }
        }
        expect((await backend.graphStats()).targetBytes, 32 * 32 * 84);
        final shader = await materials.compile(
          MeshShaderDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl(
                '${ShaderMaterial.uniformsWgsl}\n${ShaderMaterial.vertexWgsl()}\n'
                '@fragment fn fragment(v:MeshVertex)->@location(0) vec4<f32> {return vec4<f32>(1.);}',
              ),
            ),
          ),
        );
        mesh.material = ShaderMaterial(shader);
        expect((await render()).image.pixels, bytes);
        scene.remove(mesh);
        final instances = scene.add(
          InstancedMesh(
            mesh.geometry,
            StandardMaterial(
              baseColor: const Color3(0, 0, 0),
              emissive: const Color3(1, 1, 1),
            ),
            count: 2,
          ),
        );
        instances.setTransform(0, mesh.localMatrix);
        instances.setTransform(
          1,
          Mat4.compose(const Vec3(100, 0, 0), Quat.identity, Vec3.one),
        );
        expect((await render()).image.pixels, bytes);
        scene.remove(instances);
        scene.add(mesh);
        mesh.material = UnlitMaterial(color: const Color3(1, 1, 1));
        final depth = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
let p=vec2<i32>(v.position.xy);let a=textureLoad(sceneColor,p,0).a;
return vec4<f32>(textureLoad(sceneDepth,p,0)*a,0.,0.,a);
}
'''),
            ),
          ),
        );
        scene.renderSettings = scene.renderSettings.copyWith(effects: [depth]);
        final depthPixels = (await render()).image.pixels;
        final d = camera.projectPoint(Vec3.zero, 1).z;
        final encoded = d <= .0031308
            ? 12.92 * d
            : 1.055 * math.pow(d, 1 / 2.4) - .055;
        for (final i in partial) {
          expect(depthPixels[i - 3], closeTo(encoded * bytes[i], 2));
        }
        await expectLater(render(2048), throwsA(isA<SceneException>()));
        expect((await render()).image.pixels, depthPixels);
        await render(16);
        expect((await backend.graphStats()).targetBytes, 16 * 16 * 84);
        scene.renderSettings = RenderSettings();
        await render();
        expect((await backend.graphStats()).targetBytes, 0);
      } finally {
        await materials.close();
        await shaders.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
