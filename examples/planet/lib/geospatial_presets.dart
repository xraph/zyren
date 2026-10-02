import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Fixed inputs from the upstream 3D Tiles Renderer Integration stories.
enum GoogleTilesPreset {
  manhattan('Manhattan', -73.9709, 40.7589, -155, -35, 3000, 60, 1, 7.6),
  fuji('Fuji', 138.5973, 35.2138, 71, -31, 7000, 10, 260, 16),
  tokyo('Tokyo', 139.8146, 35.7455, -110, -9, 1000, 10, 170, 7.5, .35),
  cloudFuji('Fuji', 138.634, 35.5, -91, -27, 8444, 10, 200, 17.5, .4),
  london('London', -.1293, 51.4836, -94, -7, 3231, 15, 0, 9.4, .35);

  static const atmospherePresets = [manhattan, fuji];
  static const cloudPresets = [tokyo, cloudFuji, london];

  static const qualificationYear = 2026;
  final String label;
  final double longitude,
      latitude,
      heading,
      pitch,
      distance,
      exposure,
      timeOfDay;
  final int dayOfYear;
  final double? coverage;
  const GoogleTilesPreset(
    this.label,
    this.longitude,
    this.latitude,
    this.heading,
    this.pitch,
    this.distance,
    this.exposure,
    this.dayOfYear,
    this.timeOfDay, [
    this.coverage,
  ]);

  /// Matches useLocalDateControls, including its offset from January 1.
  /// Pass an explicit year so a saved fixture does not change with the calendar.
  DateTime utcDate({required int year}) => DateTime.utc(year, 1, 1).add(
    Duration(
      milliseconds: ((dayOfYear * 24 + timeOfDay - longitude / 15) * 3600000)
          .round(),
    ),
  );

  void applyCamera(Camera camera) => PointOfView(
    distance: distance,
    heading: Angle.degrees(heading),
    pitch: Angle.degrees(pitch),
  ).decompose(Geodetic.degrees(longitude, latitude).toEcef()).applyTo(camera);
}
