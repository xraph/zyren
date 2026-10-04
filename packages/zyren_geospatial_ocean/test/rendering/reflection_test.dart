import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

void main() {
  test('reflection work admission includes refinement and rejects planar', () {
    final settings = OceanReflectionSettings(stepLimit: 32, pixelBudget: 100);
    expect(settings.effectiveSteps(10, 10), 32);
    expect(settings.effectiveSteps(20, 20), 4);
    expect(settings.effectiveSteps(100, 100), 0);
    expect(
      () => OceanReflectionSettings(mode: OceanReflectionMode.planar),
      throwsUnsupportedError,
    );
    expect(() => OceanReflectionSettings(stepLimit: 65), throwsArgumentError);
  });
  test(
    'native current-depth reflection finds geometry and clears disocclusion',
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
      final camera = PerspectiveCamera(
        position: origin + const Vec3(0, -6, 3),
        target: origin,
        up: const Vec3(0, 0, 1),
        near: .1,
        far: 30,
      );
      final marker = scene.add(
        Mesh(
            PlaneGeometry(width: 2, height: 2),
            StandardMaterial(
              baseColor: const Color3(0, 0, 0),
              metallic: 1,
              emissive: const Color3(1, 0, 0),
              emissiveIntensity: 4,
            ),
          )
          ..position = origin + const Vec3(0, 2, 1)
          ..quaternion = Quat.axisAngle(const Vec3(1, 0, 0), math.pi / 2),
      );
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(128, 128),
                  colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
                ),
              )
              as ReadbackOutput;
      List<int> center(ReadbackOutput image) => image.image.pixels.sublist(
        (64 * 128 + 64) * 4,
        (64 * 128 + 64) * 4 + 4,
      );
      Future<void> save(ReadbackOutput image, String name) async {
        final path = Platform.environment['OCEAN_CAPTURE_DIR'];
        if (path == null) return;
        await Directory(path).create(recursive: true);
        final p = image.image.pixels;
        await File('$path/$name.ppm').writeAsBytes([
          ...ascii.encode('P6\n128 128\n255\n'),
          for (var i = 0; i < p.length; i += 4) ...p.sublist(i, i + 3),
        ]);
      }

      try {
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: {4: await field.evaluate(0, resolution: 8)},
        );
        for (final reversed in [false, true]) {
          camera.depthStrategy = reversed
              ? DepthStrategy.reversed
              : DepthStrategy.standard;
          marker.visible = true;
          final material = await OceanWaterMaterial.create(
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
              skyRadiance: Vec3.zero,
              groundRadiance: Vec3.zero,
            ),
            reflections: OceanReflectionSettings(
              stepLimit: 64,
              maximumDistanceMetres: 8,
              thicknessMetres: .5,
            ),
          );
          final water = scene.add(
            Mesh(PlaneGeometry(width: 20, height: 20), material.material)
              ..position = origin,
          );
          final reflected = await draw();
          await save(
            reflected,
            'reflection-${reversed ? 'reversed' : 'standard'}',
          );
          expect(center(reflected)[0], greaterThan(40));
          expect(center(reflected)[1], 0);
          marker.visible = false;
          final hidden = await draw();
          expect(center(hidden), [0, 0, 0, 255]);
          scene.remove(water);
          await material.close();
        }
        await waves.close();
      } finally {
        for (final child in scene.children.toList()) {
          scene.remove(child);
        }
        await scope.close();
        await draw();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
