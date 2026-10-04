import 'package:zyren_geospatial/zyren_geospatial.dart';

enum OceanLabFog {
  off,
  light,
  dense;

  GeoDistanceFog? get settings => switch (this) {
    off => null,
    light => GeoDistanceFog(startMetres: 1500, endMetres: 6000),
    dense => GeoDistanceFog(startMetres: 100, endMetres: 1000),
  };
}
