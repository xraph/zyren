import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test('source Manhattan and Fuji cameras and dates stay deterministic', () {
    final manhattan = GoogleTilesPreset.manhattan,
        fuji = GoogleTilesPreset.fuji;
    expect(
      [
        manhattan.longitude,
        manhattan.latitude,
        manhattan.heading,
        manhattan.pitch,
        manhattan.distance,
        manhattan.exposure,
        manhattan.dayOfYear,
        manhattan.timeOfDay,
      ],
      [-73.9709, 40.7589, -155, -35, 3000, 60, 1, 7.6],
    );
    expect(
      [
        fuji.longitude,
        fuji.latitude,
        fuji.heading,
        fuji.pitch,
        fuji.distance,
        fuji.exposure,
        fuji.dayOfYear,
        fuji.timeOfDay,
      ],
      [138.5973, 35.2138, 71, -31, 7000, 10, 260, 16],
    );
    expect(
      manhattan.utcDate(year: 2026),
      DateTime.utc(2026, 1, 2, 12, 31, 53, 16),
    );
    expect(fuji.utcDate(year: 2026), DateTime.utc(2026, 9, 18, 6, 45, 36, 648));
    final camera = PerspectiveCamera();
    for (final preset in GoogleTilesPreset.values) {
      preset.applyCamera(camera);
      final target = Geodetic.degrees(
        preset.longitude,
        preset.latitude,
      ).toEcef();
      expect(camera.target.distanceTo(target), lessThan(1e-6));
      expect(
        camera.position.distanceTo(camera.target),
        closeTo(preset.distance, 1e-6),
      );
      final expected = PointOfView(
        distance: preset.distance,
        heading: Angle.degrees(preset.heading),
        pitch: Angle.degrees(preset.pitch),
      ).decompose(target);
      final duplicate = PerspectiveCamera();
      expected.applyTo(duplicate);
      expect(camera.position, duplicate.position);
      expect(camera.up, duplicate.up);
    }
  });
}
