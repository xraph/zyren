import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';
import 'underwater_test.dart' show srgb;

void main() {
  test(
    'native Snell window keeps water attenuation once and survives near-plane changes',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 4),
      );
      final waves = await OceanWaveRenderData.pack(
        scope,
        state: state,
        charts: {4: await field.evaluate(0, resolution: 8)},
      );
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final optics = OceanOptics(
        absorptionPerMetre: const Vec3(.5, .5, .5),
        scatteringPerMetre: Vec3.zero,
      );
      final light = OceanLighting(
        sunIrradiance: Vec3.zero,
        skyRadiance: const Vec3(.2, .4, .6),
        groundRadiance: const Vec3(.2, .4, .6),
      );
      final water = await OceanWaterMaterial.create(
        scope,
        waves: waves,
        patch: patch,
        geometrySpacingMetres: .1,
        optics: optics,
        lighting: light,
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(hdr: true, backgroundAlpha: 0);
      final mesh = scene.add(
        Mesh(PlaneGeometry(width: 100, height: 100), water.material)
          ..position = origin,
      );
      final camera = PerspectiveCamera(
        position: origin - const Vec3(0, 0, 1),
        target: origin,
        near: .05,
        far: 200,
      );
      final size = PhysicalSize(33, 33);
      final capture = await OceanSurfaceCapture.create(
        scope,
        backend,
        draws: [OceanBoundaryDraw(water: water, mesh: mesh)],
        size: size,
      );
      final pass = await OceanUnderwaterPass.create(
        scope,
        surface: capture,
        optics: optics,
        lighting: light,
      );
      Future<List<int>> draw({double signedDistance = -1}) async {
        await capture.update(camera);
        await pass.prepare(
          camera: camera,
          viewport: size,
          signedSurfaceDistance: signedDistance,
          surfaceUp: const Vec3(0, 0, 1),
        );
        pass.attach(scene);
        final frame =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: size,
                    colorPipeline: ColorPipeline(
                      toneMapping: ToneMapping.linear,
                    ),
                  ),
                )
                as ReadbackOutput;
        return frame.image.pixels.sublist(
          (16 * 33 + 16) * 4,
          (16 * 33 + 16) * 4 + 4,
        );
      }

      try {
        for (final strategy in DepthStrategy.values) {
          camera.depthStrategy = strategy;
          camera.target = origin;
          for (final near in [.05, 2.0]) {
            camera.near = near;
            final color = await draw();
            for (var c = 0; c < 3; c++) {
              final expected =
                  [.2, .4, .6][c] *
                  (1 - waterFresnel(1, 1.333, 1)) *
                  math.exp(-.5);
              expect(
                color[c],
                closeTo(srgb(expected), 2),
                reason: 'near=$near strategy=$strategy',
              );
            }
            expect(color[3], 255);
          }
          camera.near = .05;
          camera.target = origin + const Vec3(5, 0, 0);
          expect(await draw(), [0, 0, 0, 255], reason: strategy.name);
        }
        camera.target = origin;
        camera.near = .05;
        camera.position = origin + const Vec3(0, 0, 1);
        await draw(signedDistance: 1);
        final before = await backend.resourceStats();
        for (var i = 0; i < 100; i++) {
          final distance = i.isEven ? -1.0 : 1.0;
          camera.position = origin + Vec3(0, 0, distance);
          final color = await draw(signedDistance: distance);
          expect(color[3], 255);
        }
        final after = await backend.resourceStats();
        expect(after.liveAllocations, before.liveAllocations);
        expect(after.residentBytes, before.residentBytes);
      } finally {
        await pass.close();
        await capture.close();
        await scope.close();
        scene.remove(mesh);
        await backend.render(
          FrameSubmission.capture(scene: scene, camera: camera, size: size),
        );
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
