import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';
import 'events_test.dart' show initial;

void main() {
  test(
    'native foam uses wave compression and covered shallow depth, with no calm breakers',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final patch = OceanPatchId(face: 0, level: 16, x: 32768, y: 32768);
      final anchor = patch.point(.5, .5);
      final field = await OceanInteractionField.create(
        owner,
        anchorEcef: anchor,
        initialTime: initial,
        settings: OceanInteractionSettings(resolution: 32, extentMetres: 16),
      );
      final retainedSources = await owner.resources.retain(field.foamSources);
      final center = Ellipsoid.wgs84.fromEcef(anchor);
      final depth = OceanFoamDepthMap(
        sourceId: 'fixture.coast',
        revision: '1',
        meanLevelMetres: 0,
        grid: GeoScalarGrid(
          width: 4,
          height: 4,
          bounds: GeographicRectangle(
            center.longitude - .0000013,
            center.latitude - .0000013,
            center.longitude + .0000013,
            center.latitude + .0000013,
          ),
          values: Float64List.fromList(
            List.generate(16, (i) => i % 4 < 2 ? .5 : double.nan),
          ),
        ),
      );
      try {
        for (final wind in [0.0, 20.0]) {
          final state = fixtureSea(wind: wind, resolution: 32);
          final waves = await OceanWaveFieldGpu.create(
            owner,
            oceanChartSeaState(state, 0),
          );
          final packed = await OceanWaveRenderData.pack(
            owner,
            state: state,
            charts: {0: await waves.evaluate(2, resolution: 32)},
          );
          final water = await OceanWaterMaterial.create(
            owner,
            waves: packed,
            patch: patch,
            geometrySpacingMetres: .5,
          );
          final source = await OceanFoamProducer.create(
            owner,
            water: water,
            field: field,
            depth: depth,
            settings: OceanFoamSettings(
              compressionThreshold: 1,
              whitecapRate: 5,
              shoreRate: 3,
            ),
          );
          await source.update();
          final bytes = await owner.resources.readTexture(retainedSources);
          final data = ByteData.sublistView(bytes);
          var maxWhite = 0.0, maxShore = 0.0;
          for (var y = 0; y < 32; y++) {
            for (var x = 0; x < 32; x++) {
              final at = (y * 32 + x) * 16;
              final white = data.getFloat32(at, Endian.little),
                  shore = data.getFloat32(at + 4, Endian.little);
              expect(white, inInclusiveRange(0, 5));
              expect(shore, inInclusiveRange(0, 3));
              if (white > maxWhite) maxWhite = white;
              if (shore > maxShore) maxShore = shore;
              if (x >= 16) {
                expect(shore, 0, reason: 'unknown bathymetry must not emit');
              }
            }
          }
          if (wind == 0) {
            expect(maxWhite, lessThan(1e-5));
            expect(maxShore, lessThan(1e-5));
          } else {
            expect(maxWhite, greaterThan(.001));
            expect(maxShore, greaterThan(.001));
          }
          await source.close();
          await water.close();
          await packed.close();
          await waves.close();
        }
        final state = fixtureSea(wind: 20);
        final waves = await OceanWaveFieldGpu.create(
          owner,
          oceanChartSeaState(state, 0),
        );
        final packed = await OceanWaveRenderData.pack(
          owner,
          state: state,
          charts: {0: await waves.evaluate(0, resolution: 8)},
        );
        final water = await OceanWaterMaterial.create(
          owner,
          waves: packed,
          patch: patch,
          geometrySpacingMetres: 1,
        );
        final source = await OceanFoamProducer.create(
          owner,
          water: water,
          field: field,
        );
        await source.update();
        final data = ByteData.sublistView(
          await owner.resources.readTexture(retainedSources),
        );
        for (var i = 0; i < 32 * 32; i++) {
          expect(data.getFloat32(i * 16 + 4, Endian.little), 0);
        }
        await field.recenter(anchor + field.east);
        await expectLater(source.update(), throwsStateError);
        expect(field.isFaulted, isFalse);
        expect(
          (await owner.resources.readTexture(
            retainedSources,
          )).every((v) => v == 0),
          isTrue,
        );
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
