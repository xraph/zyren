import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native boundary capture matches surface side and survives near clipping',
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
      final mesh = Mesh(PlaneGeometry(width: 4, height: 4), water.material)
        ..position = origin;
      final camera = PerspectiveCamera(
        position: origin + const Vec3(0, 0, 3),
        target: origin,
        near: 4,
        far: 20,
      );
      final size = PhysicalSize(32, 32);
      final capture = await OceanSurfaceCapture.create(
        scope,
        backend,
        draws: [OceanBoundaryDraw(water: water, mesh: mesh)],
        size: size,
      );
      final retained = await scope.resources.retain(capture.texture);
      Future<List<double>> sample() async {
        final receipt = await capture.update(camera);
        expect(receipt.readbackBytes, 0);
        capture.checkCurrent(camera, size);
        final bytes = ByteData.sublistView(
          await scope.resources.readTexture(retained),
        );
        return [
          for (var c = 0; c < 4; c++)
            half(bytes.getUint16((16 * 32 + 16) * 8 + 2 * c, Endian.little)),
        ];
      }

      try {
        for (final strategy in DepthStrategy.values) {
          camera.depthStrategy = strategy;
          final front = await sample();
          expect(front[0] * 32 + front[1], closeTo(3, .01));
          expect(front[2], 1);
          expect(front[3], 1);
          camera.position = origin - const Vec3(0, 0, 3);
          expect(() => capture.checkCurrent(camera, size), throwsStateError);
          final back = await sample();
          expect(back[0] * 32 + back[1], closeTo(3, .01));
          expect(back[2], 2);
          camera.position = origin + const Vec3(0, 0, 3);
        }
        mesh.visible = false;
        expect((await sample())[3], 0);
        mesh.visible = true;
        await sample();
        mesh.position = origin + const Vec3(0, 0, .1);
        expect(() => capture.checkCurrent(camera, size), throwsStateError);
        expect((await sample())[1], closeTo(2.9, .01));
      } finally {
        await capture.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

double half(int bits) {
  final exponent = (bits >> 10) & 31, mantissa = bits & 1023;
  final sign = bits & 0x8000 == 0 ? 1.0 : -1.0;
  return sign *
      (exponent == 0
          ? math.pow(2, -14) * mantissa / 1024
          : math.pow(2, exponent - 15) * (1 + mantissa / 1024));
}
