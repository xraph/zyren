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
    'native water matches controlled optical depth and keeps foregrounds',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 4),
      );
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final scene = Scene();
      final camera = OrthographicCamera(
        verticalSize: 4,
        near: .1,
        far: 20,
        position: origin + const Vec3(0, 0, 3),
        target: origin,
      );
      final background = scene.add(
        Mesh(
          PlaneGeometry(width: 20, height: 20),
          StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            metallic: 1,
            emissive: const Color3(1, 1, 1),
            emissiveIntensity: 1,
          ),
        )..position = origin + const Vec3(0, 0, -2),
      );
      final foreground = scene.add(
        Mesh(
          PlaneGeometry(width: .4, height: .4),
          UnlitMaterial(color: const Color3(0, 1, 0)),
        )..position = origin + const Vec3(1, 1, 1),
      );
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(64, 64),
                  colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
                ),
              )
              as ReadbackOutput;
      List<int> pixel(ReadbackOutput image, int x, int y) =>
          image.image.pixels.sublist((y * 64 + x) * 4, (y * 64 + x) * 4 + 4);
      int srgb(double linear) =>
          (255 *
                  (linear <= .0031308
                      ? 12.92 * linear
                      : 1.055 * math.pow(linear, 1 / 2.4) - .055))
              .round();
      try {
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: {4: await field.evaluate(0, resolution: 8)},
        );
        for (final deformed in [false, true]) {
          final water = await OceanWaterMaterial.create(
            scope,
            waves: waves,
            patch: patch,
            geometrySpacingMetres: .1,
            deformed: deformed,
            optics: OceanOptics(
              absorptionPerMetre: const Vec3(1, 2, 3),
              scatteringPerMetre: Vec3.zero,
            ),
            lighting: OceanLighting(
              sunIrradiance: Vec3.zero,
              skyRadiance: Vec3.zero,
              groundRadiance: Vec3.zero,
            ),
            reflections: OceanReflectionSettings(
              mode: OceanReflectionMode.disabled,
            ),
          );
          final geometry = deformed
              ? BufferGeometry(
                  positions: [-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0],
                  normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
                  indices: [0, 1, 2, 0, 2, 3],
                  morphTargets: [
                    MorphTarget(
                      name: 'flat-fixture',
                      positions: List.filled(12, 0),
                    ),
                  ],
                )
              : PlaneGeometry(width: 4, height: 4);
          final mesh = scene.add(
            Mesh(geometry, water.material)..position = origin,
          );
          if (deformed) mesh.morphWeights = [0];
          for (final reversed in [false, true]) {
            camera.depthStrategy = reversed
                ? DepthStrategy.reversed
                : DepthStrategy.standard;
            final rendered = await draw();
            final actual = pixel(rendered, 32, 32);
            final f = 1 - waterFresnel(1, 1, 1.333);
            for (var c = 0; c < 3; c++) {
              expect(actual[c], closeTo(srgb(f * math.exp(-2 * (c + 1))), 2));
            }
            expect(pixel(rendered, 48, 16), [0, 255, 0, 255]);
            expect(actual[3], 255);
          }
          scene.remove(mesh);
          await water.close();
        }
        background.visible = false;
        foreground.visible = false;
        final blue = await OceanWaterMaterial.create(
          scope,
          waves: waves,
          patch: patch,
          geometrySpacingMetres: .1,
          optics: OceanOptics(
            absorptionPerMetre: Vec3.zero,
            scatteringPerMetre: Vec3.zero,
          ),
          lighting: OceanLighting(
            sunIrradiance: Vec3.zero,
            skyRadiance: const Vec3(0, 0, 4),
            groundRadiance: const Vec3(0, 0, 4),
          ),
          reflections: OceanReflectionSettings(
            mode: OceanReflectionMode.environment,
          ),
        );
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 4, height: 4), blue.material)
            ..position = origin,
        );
        final reflected = pixel(await draw(), 32, 32);
        expect(reflected[0], 0);
        expect(reflected[1], 0);
        expect(reflected[2], closeTo(srgb(4 * waterFresnel(1, 1, 1.333)), 2));
        scene.remove(mesh);
        await blue.close();
        await waves.close();
      } finally {
        await scope.close();
        for (final child in scene.children.toList()) {
          scene.remove(child);
        }
        await draw();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
