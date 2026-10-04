import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

OceanReferenceSample bilinear(
  OceanSpectrum spectrum,
  double u,
  double v,
  double time,
) {
  const n = 8, length = 64.0;
  final x = (u % length) / length * n, y = (v % length) / length * n;
  final values = List.filled(12, 0.0);
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final s = spectrum.reference(
        ((x.floor() + dx) % n) * length / n,
        ((y.floor() + dy) % n) * length / n,
        time,
      );
      final w = (dx == 0 ? 1 - x % 1 : x % 1) * (dy == 0 ? 1 - y % 1 : y % 1);
      final channels = [
        s.height,
        s.displacementX,
        s.displacementZ,
        s.slopeX,
        s.slopeZ,
        s.velocityX,
        s.velocityY,
        s.velocityZ,
        s.displacementXX,
        s.displacementXZ,
        s.displacementZX,
        s.displacementZZ,
      ];
      for (var i = 0; i < 12; i++) {
        values[i] += w * channels[i];
      }
    }
  }
  return OceanReferenceSample(
    height: values[0],
    displacementX: values[1],
    displacementZ: values[2],
    slopeX: values[3],
    slopeZ: values[4],
    velocityX: values[5],
    velocityY: values[6],
    velocityZ: values[7],
    displacementXX: values[8],
    displacementXZ: values[9],
    displacementZX: values[10],
    displacementZZ: values[11],
  );
}

void main() {
  test(
    'native material field matches fixed-chart reference at poles and overlaps',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea();
      final sources = <int, OceanFieldSnapshot>{};
      final reference = <int, OceanSpectrum>{};
      try {
        for (var id = 0; id < 6; id++) {
          final chart = oceanChartSeaState(state, id);
          reference[id] = OceanSpectrum(chart);
          final field = await OceanWaveFieldGpu.create(scope, chart);
          sources[id] = await field.evaluate(2.5, resolution: 8);
        }
        final waves = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: sources,
        );
        final charts = OceanWaveCharts(seed: state.seed);
        for (final patch in [
          OceanPatchId(face: 4, level: 20, x: 524288, y: 524288),
          OceanPatchId(face: 0, level: 20, x: 1048575, y: 524288),
          OceanPatchId(face: 0, level: 20, x: 1048575, y: 1048575),
          OceanPatchId(face: 5, level: 20, x: 524288, y: 524288),
        ]) {
          final origin = patch.point(.5, .5);
          final material = await OceanWaterMaterial.create(
            scope,
            waves: waves,
            patch: patch,
            geometrySpacingMetres: .1,
          );
          final positions = [origin, patch.point(.1, .8), patch.point(.9, .2)];
          final local = [for (final p in positions) p - origin];
          final actual = await material.debugSurface(local);
          for (var i = 0; i < positions.length; i++) {
            final point = charts.atSurface(positions[i]);
            final expected = blendOceanSurface(
              point,
              (c) => bilinear(reference[c.id]!, c.u, c.v, 2.5),
            );
            expect(
              (actual[i].offsetEcef - (expected.position - positions[i]))
                  .length,
              lessThan(2e-5),
            );
            expect(
              (actual[i].normalEcef - expected.normal).length,
              lessThan(2e-5),
            );
          }
          final coarse = await material.debugSurface([
            Vec3.zero,
          ], footprintMetres: 128);
          expect(coarse.single.offsetEcef.length, lessThan(1e-5));
          expect(coarse.single.unresolvedSlopeVariance, greaterThan(0));
          expect(
            (coarse.single.normalEcef - Ellipsoid.wgs84.surfaceNormal(origin))
                .length,
            lessThan(1e-5),
          );
          await material.close();
        }
        await waves.close();
      } finally {
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
