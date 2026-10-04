import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';
import 'underwater_test.dart' show srgb;

void main() {
  test(
    'native water transport and atmosphere compose once in the same frame',
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
        ..renderSettings = RenderSettings(
          hdr: true,
          backgroundAlpha: 0,
          toneMapping: ToneMapping.linear,
        );
      final floor = scene.add(
        Mesh(
          PlaneGeometry(width: 20, height: 20),
          UnlitMaterial(color: const Color3(1, 1, 1)),
        )..position = origin - const Vec3(0, 0, 3),
      );
      final camera = OrthographicCamera(
        position: origin - const Vec3(0, 0, 1),
        target: floor.position,
        near: .1,
        far: 20,
        verticalSize: 4,
      );
      final atmosphere = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        correctAltitude: false,
        appearance: AtmosphereAppearance(sky: false),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [atmosphere],
      );
      final optics = OceanOptics(
        absorptionPerMetre: const Vec3(1, .5, .25),
        scatteringPerMetre: const Vec3(.1, .2, .3),
      );
      final light = OceanLighting(
        skyRadiance: const Vec3(.2, .3, .4),
        sunIrradiance: Vec3.zero,
      );
      final pass = await OceanUnderwaterPass.create(
        scope,
        surface: capture,
        optics: optics,
        lighting: light,
        transportSize: size,
      );
      try {
        await atmosphere.controller.setAerialInputs(
          AerialPerspectiveInputs(medium: pass.aerialMedium),
        );
        await capture.update(camera);
        await pass.prepare(
          camera: camera,
          viewport: size,
          signedSurfaceDistance: -1,
          surfaceUp: const Vec3(0, 0, 1),
        );
        pass.attach(scene);
        final expected = optics
            .integrate(Vec3.one, light.skyRadiance, 2)
            .storage
            .map(srgb)
            .toList();
        for (final haze in [true, false, true]) {
          atmosphere.controller.appearance = atmosphere.controller.appearance
              .copyWith(haze: haze);
          final frame = await engine.render(
            elapsed: Duration.zero,
            width: 32,
            height: 32,
          );
          final actual = frame.pixels.sublist(
            (16 * 32 + 16) * 4,
            (16 * 32 + 16) * 4 + 4,
          );
          for (var c = 0; c < 3; c++) {
            expect(actual[c], closeTo(expected[c], 2));
          }
          expect(actual[3], 255);
        }
        floor.visible = false;
        final empty = await engine.render(
          elapsed: Duration.zero,
          width: 32,
          height: 32,
        );
        expect(empty.pixels, everyElement(0));
      } finally {
        await pass.close();
        await engine.dispose();
        await capture.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
