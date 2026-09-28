import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'transparent meshes and instances stay back-to-front in either depth mode',
    () async {
      final backend = await NativeBackend.create();
      try {
        for (final strategy in DepthStrategy.values) {
          for (final instanced in [false, true]) {
            for (final writes in [DepthWrite.automatic, DepthWrite.enabled]) {
              final scene = Scene()..background = const Color3(0, 0, 0);
              final camera = PerspectiveCamera(depthStrategy: strategy);
              final geometry = PlaneGeometry(width: 4, height: 4);
              for (final (z, color) in [
                (1.0, const Color3(1, 0, 0)),
                (0.0, const Color3(0, 1, 0)),
              ]) {
                final material = UnlitMaterial(
                  color: color,
                  alphaMode: MaterialAlphaMode.blend,
                  opacity: .5,
                  depthWrite: writes,
                );
                scene.add(
                  (instanced
                        ? InstancedMesh(geometry, material, count: 1)
                        : Mesh(geometry, material))
                    ..position = Vec3(0, 0, z),
                );
              }
              final frame =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(33, 33),
                        ),
                      )
                      as ReadbackOutput;
              final center = frame.image.pixels.sublist(
                (16 * 33 + 16) * 4,
                (16 * 33 + 16) * 4 + 4,
              );
              for (final (index, expected) in [188, 137, 0, 255].indexed) {
                expect(
                  center[index],
                  closeTo(expected, 1),
                  reason: '$strategy instances=$instanced writes=$writes',
                );
              }
              expect(frame.stats.drawCalls, 2);
            }
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'screen helpers reconstruct near, surface and background depth in both modes',
    () async {
      final backend = await NativeBackend.create();
      final shaders = backend.createShaderCompiler();
      final materials = backend.createMaterialCompiler();
      try {
        final effect = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
  let depth = textureLoad(sceneDepth,vec2<i32>(v.position.xy),0);
  if sceneDepthIsBackground(depth) { return vec4<f32>(0.,0.,1.,1.); }
  let point = scenePosition(v.uv,depth);
  let near = scenePosition(v.uv,sceneNearDepth());
  let valid = abs(point.z + 3.) < .00001 && abs(near.z + .1) < .00001;
  return select(vec4<f32>(1.,0.,0.,1.),vec4<f32>(0.,1.,0.,1.),valid);
}
'''),
            ),
          ),
        );
        final scene = Scene();
        scene.add(Mesh(PlaneGeometry(), UnlitMaterial()));
        for (final strategy in DepthStrategy.values) {
          for (final sampleCount in [1, 4]) {
            scene.renderSettings = RenderSettings(
              effects: [effect],
              sampleCount: sampleCount,
            );
            for (final camera in <Camera>[
              PerspectiveCamera(
                position: const Vec3(0, 0, 3),
                near: .1,
                far: 10,
                depthStrategy: strategy,
              ),
              OrthographicCamera(
                position: const Vec3(0, 0, 3),
                near: .1,
                far: 10,
                depthStrategy: strategy,
              ),
            ]) {
              final frame =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(33, 33),
                        ),
                      )
                      as ReadbackOutput;
              final pixels = frame.image.pixels;
              expect(
                pixels.sublist((16 * 33 + 16) * 4, (16 * 33 + 16) * 4 + 3),
                [0, 255, 0],
              );
              expect(pixels.sublist(0, 3), [0, 0, 255]);
            }
          }
        }
      } finally {
        await materials.close();
        await shaders.close();
        expect((await backend.graphStats()).liveMaterials, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'reversed float depth separates surfaces at horizon and orbit distances',
    () async {
      final backend = await NativeBackend.create();
      final camera = PerspectiveCamera(
        position: const Vec3(6378137, 0, 0),
        target: const Vec3(6378137, 0, -1),
        near: .1,
        far: 1e9,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      try {
        for (final sampleCount in [1, 4]) {
          scene.renderSettings = RenderSettings(sampleCount: sampleCount);
          for (final (distance, separation) in [
            (1.0, .001),
            (1000.0, .001),
            (100000.0, 1.0),
            (10000000.0, 10.0),
          ]) {
            final geometry = PlaneGeometry(width: distance, height: distance);
            final far = scene.add(
              Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0)))
                ..position =
                    camera.position + Vec3(0, 0, -distance - separation),
            );
            final near = scene.add(
              Mesh(geometry, UnlitMaterial(color: const Color3(0, 1, 0)))
                ..position = camera.position + Vec3(0, 0, -distance),
            );
            for (final strategy in [
              DepthStrategy.reversed,
              DepthStrategy.standard,
              DepthStrategy.reversed,
            ]) {
              camera.depthStrategy = strategy;
              final frame =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(33, 33),
                        ),
                      )
                      as ReadbackOutput;
              final center = frame.image.pixels.sublist(
                (16 * 33 + 16) * 4,
                (16 * 33 + 16) * 4 + 3,
              );
              if (strategy == DepthStrategy.reversed) {
                expect(
                  center,
                  [0, 255, 0],
                  reason:
                      '$distance metres, $separation gap, $sampleCount samples',
                );
              } else if (distance >= 100000) {
                expect(
                  center,
                  isNot([0, 255, 0]),
                  reason: 'standard depth loses this separation',
                );
              }
            }
            scene.remove(far);
            scene.remove(near);
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
