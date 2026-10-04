import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'fixed native optical scenes vary roughness and sunlight with spectral waves',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = OceanSeaState(
        seed: 42,
        canonicalResolution: 256,
        bands: [
          OceanWaveBand(
            patchMetres: 128,
            minWaveNumber: 0,
            maxWaveNumber: 2,
            windSpeed: 12,
            windHeadingRadians: .3,
            amplitude: .008,
            choppiness: .6,
          ),
        ],
      );
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 4),
      );
      final patch = OceanPatchId(face: 4, level: 14, x: 8192, y: 8192);
      final origin = patch.point(.5, .5);
      final scene = Scene()..background = const Color3(.25, .35, .5);
      final camera = PerspectiveCamera(
        position: origin + const Vec3(0, -25, 20),
        target: origin,
        up: const Vec3(0, 0, 1),
        near: .2,
        far: 500,
      );
      final positions = <double>[], normals = <double>[], indices = <int>[];
      const segments = 256, extent = 256.0;
      for (var y = 0; y <= segments; y++) {
        for (var x = 0; x <= segments; x++) {
          positions.addAll([
            (x / segments - .5) * extent,
            (y / segments - .5) * extent,
            0,
          ]);
          normals.addAll([0, 0, 1]);
        }
      }
      for (var y = 0; y < segments; y++) {
        for (var x = 0; x < segments; x++) {
          final a = y * (segments + 1) + x,
              b = a + 1,
              c = a + segments + 1,
              d = c + 1;
          indices.addAll([a, b, d, a, d, c]);
        }
      }
      final geometry = BufferGeometry(
        positions: positions,
        normals: normals,
        indices: indices,
      );
      scene.add(
        Mesh(
          BoxGeometry(width: 3, height: 3, depth: 3),
          UnlitMaterial(color: const Color3(.65, .06, .015)),
        )..position = origin + const Vec3(3, 3, 0),
      );
      scene.add(
        Mesh(
          BoxGeometry(width: 5, height: 5, depth: 1),
          UnlitMaterial(color: const Color3(.8, .7, .25)),
        )..position = origin + const Vec3(-4, 0, -2.5),
      );
      final floor = scene.add(
        Mesh(
          PlaneGeometry(width: 70, height: 70),
          UnlitMaterial(color: const Color3(.55, .55, .45)),
        )..position = origin + const Vec3(0, 0, -7),
      );
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(480, 320),
                  colorPipeline: ColorPipeline(
                    toneMapping: ToneMapping.acesFilmic,
                    sampleCount: 4,
                  ),
                ),
              )
              as ReadbackOutput;
      try {
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: {4: await field.evaluate(6, resolution: 256)},
        );
        final cache = AtmosphereLutCache(scope);
        final lease = await cache.acquire(
          parameters: AtmosphereParameters.legacy(),
        );
        final sums = <int>[];
        for (final (name, roughness, direction) in [
          ('sun-low', .07, const Vec3(0, 1, .35)),
          ('sun-high', .07, const Vec3(0, 1, 1.5)),
          ('rough', .45, const Vec3(0, 1, .35)),
          ('night', .07, const Vec3(0, 0, -1)),
        ]) {
          final material = await OceanWaterMaterial.create(
            scope,
            waves: waves,
            patch: patch,
            geometrySpacingMetres: 1,
            optics: OceanOptics(roughness: roughness),
            lighting: OceanLighting(
              atmosphere: lease.luts,
              sunDirectionEcef: direction,
            ),
            reflections: OceanReflectionSettings(
              stepLimit: 32,
              maximumDistanceMetres: 50,
            ),
          );
          final water = scene.add(
            Mesh(geometry, material.material)..position = origin,
          );
          final image = (await draw()).image.pixels;
          final sample = ((240 * 480) + 240) * 4;
          sums.add(image[sample] + image[sample + 1] + image[sample + 2]);
          expect([
            for (var i = 3; i < image.length; i += 4) image[i],
          ], everyElement(255));
          final path = Platform.environment['OCEAN_CAPTURE_DIR'];
          if (path != null) {
            await Directory(path).create(recursive: true);
            await File('$path/$name.ppm').writeAsBytes([
              ...ascii.encode('P6\n480 320\n255\n'),
              for (var i = 0; i < image.length; i += 4)
                ...image.sublist(i, i + 3),
            ]);
          }
          scene.remove(water);
          await material.close();
        }
        expect(sums[0], isNot(sums[2]));
        expect(sums[1], greaterThan(sums[3]));
        await lease.close();
        await cache.close();
        await waves.close();
        floor.visible = false;
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
