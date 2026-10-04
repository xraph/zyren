import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'foam visibility changes native shading without changing wave geometry',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final instant = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
      try {
        final waves = await OceanWaveStream.create(
          scope,
          state: state,
          chartIds: [4],
          resolution: 8,
          bandCount: 1,
        );
        final field = await OceanInteractionField.create(
          scope,
          anchorEcef: origin,
          initialTime: instant,
          settings: OceanInteractionSettings(
            resolution: 16,
            extentMetres: 16,
            absorbingWidthCells: 4,
          ),
        );
        final foam = Float32List(16 * 16 * 4);
        for (var i = 0; i < 256; i++) {
          foam[i * 4] = 10;
        }
        await field.writeFoamSources(foam);
        await field.step(instant.withTick(1));
        final water = await OceanWaterMaterial.create(
          scope,
          waves: waves,
          patch: patch,
          geometrySpacingMetres: .1,
          interactions: field,
          debug: OceanWaterDebug.foam,
        );
        final scene = Scene()..renderSettings = RenderSettings(hdr: true);
        scene.add(
          Mesh(PlaneGeometry(width: 16, height: 16), water.material)
            ..position = origin,
        );
        final camera = PerspectiveCamera(
          position: origin + const Vec3(0, 0, 5),
          target: origin,
          near: .1,
          far: 20,
        );
        Future<int> pixel() async {
          final result =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(32, 32),
                    ),
                  )
                  as ReadbackOutput;
          return result.image.pixels[(16 * 32 + 16) * 4];
        }

        final before = (await water.debugSurface([Vec3.zero])).single;
        expect(await pixel(), greaterThan(20));
        await water.setFoamEnabled(false);
        expect(await pixel(), 0);
        final after = (await water.debugSurface([Vec3.zero])).single;
        expect(after.offsetEcef, before.offsetEcef);
        expect(after.foam, before.foam);
        await water.setFoamEnabled(true);
        expect(await pixel(), greaterThan(20));
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
