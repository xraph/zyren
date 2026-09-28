import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'scene options reject invalid ranges, nonrigid frames and copy lunar data',
    () {
      final date = DateTime.utc(2026);
      for (final size in [0, 2049]) {
        expect(
          () => AtmospherePlugin(date: date, maxStarResolution: size),
          throwsArgumentError,
        );
      }
      for (final frame in [
        Mat4.compose(Vec3.zero, Quat.identity, const Vec3(2, 2, 2)),
        Mat4.compose(Vec3.zero, Quat.identity, const Vec3(-1, 1, 1)),
      ]) {
        expect(
          () => AtmospherePlugin(date: date, worldToEcef: frame),
          throwsArgumentError,
        );
      }
      expect(
        () => AtmosphereAppearance(starIntensity: double.nan),
        throwsArgumentError,
      );
      expect(
        () => AtmosphereAppearance(starPointSize: .5),
        throwsArgumentError,
      );
      expect(
        () => AtmosphereAppearance(moonAngularRadius: 0),
        throwsArgumentError,
      );
      expect(
        () => MoonMap(width: 2, height: 2, pixels: Uint8List(4)),
        throwsArgumentError,
      );
      final pixels = Uint8List.fromList([1, 2, 3, 4]);
      final map = MoonMap(width: 1, height: 1, pixels: pixels);
      pixels[0] = 255;
      map.pixels[1] = 255;
      expect(map.pixels, [1, 2, 3, 4]);
      expect(
        () => StarCatalog.fromBytes(Uint8List(163850)),
        throwsArgumentError,
      );
    },
  );
}
