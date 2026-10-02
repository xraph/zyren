import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Fixed inputs from the upstream 3D Tiles Renderer Integration stories.
enum GoogleTilesPreset {
  manhattan('Manhattan', -73.9709, 40.7589, -155, -35, 3000, 60, 1, 7.6),
  fuji('Fuji', 138.5973, 35.2138, 71, -31, 7000, 10, 260, 16);

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
  const GoogleTilesPreset(
    this.label,
    this.longitude,
    this.latitude,
    this.heading,
    this.pitch,
    this.distance,
    this.exposure,
    this.dayOfYear,
    this.timeOfDay,
  );

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
