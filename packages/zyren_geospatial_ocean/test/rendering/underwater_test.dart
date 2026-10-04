import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native underwater clips water distance and atomically replaces effects',
    () async {
      final backend = await NativeBackend.create(
        experimentalAppleSurfaces: true,
      );
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
      final water = await OceanWaterMaterial.create(
        scope,
        waves: waves,
        patch: patch,
        geometrySpacingMetres: .1,
      );
      final waterMesh = Mesh(
        PlaneGeometry(width: 20, height: 20),
        water.material,
      )..position = origin;
      final size = PhysicalSize(32, 32);
      final capture = await OceanSurfaceCapture.create(
        scope,
        backend,
        draws: [OceanBoundaryDraw(water: water, mesh: waterMesh)],
        size: size,
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(backgroundAlpha: 0, hdr: true);
      final floor = scene.add(
        Mesh(
          PlaneGeometry(width: 20, height: 20),
          UnlitMaterial(
            color: const Color3(1, 1, 1),
            side: MaterialSide.doubleSided,
          ),
        )..position = origin - const Vec3(0, 0, 3),
      );
      final optics = OceanOptics(
        absorptionPerMetre: const Vec3(1, .5, .25),
        scatteringPerMetre: Vec3.zero,
      );
      final dark = OceanLighting(
        sunIrradiance: Vec3.zero,
        skyRadiance: Vec3.zero,
      );
      OceanUnderwaterPass? active;
      Future<List<int>> draw(Camera camera) async {
        final output =
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
        return output.image.pixels.sublist(
          (16 * 32 + 16) * 4,
          (16 * 32 + 16) * 4 + 4,
        );
      }

      try {
        for (final perspective in [false, true]) {
          for (final reversed in [false, true]) {
            final camera = perspective
                ? PerspectiveCamera(
                    position: origin - const Vec3(0, 0, 1),
                    target: floor.position,
                    near: .1,
                    far: 20,
                  )
                : OrthographicCamera(
                    position: origin - const Vec3(0, 0, 1),
                    target: floor.position,
                    near: .1,
                    far: 20,
                    verticalSize: 4,
                  );
            camera.depthStrategy = reversed
                ? DepthStrategy.reversed
                : DepthStrategy.standard;
            await capture.update(camera);
            final pass = await OceanUnderwaterPass.create(
              scope,
              surface: capture,
              optics: optics,
              lighting: dark,
            );
            await pass.prepare(
              camera: camera,
              viewport: size,
              signedSurfaceDistance: -1,
              surfaceUp: const Vec3(0, 0, 1),
            );
            pass.attach(scene);
            await active?.close();
            active = pass;
            expect(scene.effects.length, 1);
            final result = await draw(camera);
            for (var c = 0; c < 3; c++) {
              expect(
                result[c],
                closeTo(srgb(math.exp(-[1, .5, .25][c] * 2)), 2),
              );
            }
            floor.visible = false;
            expect(await draw(camera), [0, 0, 0, 0]);
            floor.visible = true;
            // The configured pool ends one metre into this two metre view ray.
            final bounded = await OceanUnderwaterPass.create(
              scope,
              surface: capture,
              optics: optics,
              lighting: dark,
              volume: OceanWaterVolume.box(
                min: origin + const Vec3(-5, -5, -2),
                max: origin + const Vec3(5, 5, 0),
              ),
            );
            await bounded.prepare(
              camera: camera,
              viewport: size,
              signedSurfaceDistance: -1,
              surfaceUp: const Vec3(0, 0, 1),
            );
            bounded.attach(scene);
            await active.close();
            active = bounded;
            final clipped = await draw(camera);
            for (var c = 0; c < 3; c++) {
              expect(clipped[c], closeTo(srgb(math.exp(-[1, .5, .25][c])), 2));
            }
            expect(scene.effects.length, 1);
          }
        }
      } finally {
        await active?.close();
        await capture.close();
        await scope.close();
        scene.remove(floor);
        await draw(PerspectiveCamera());
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

int srgb(double value) =>
    (255 *
            (value <= .0031308
                ? 12.92 * value
                : 1.055 * math.pow(value, 1 / 2.4) - .055))
        .round();
