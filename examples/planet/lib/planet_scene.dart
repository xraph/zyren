import 'dart:math' as math;
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

const locations = <String, (double, double)>{
  'Lagos': (3.3792, 6.5244),
  'London': (-.1276, 51.5072),
  'Chicago': (-87.6298, 41.8781),
  'Tokyo': (139.6917, 35.6895),
  'Sydney': (151.2093, -33.8688),
};

Scene createPlanet(GeospatialReference reference) {
  final scene = Scene()
    ..background = Color3.hex(0x080e19)
    ..ambient = .35;
  scene.lightDirection = Vector3(2, -3, 4);
  scene.add(
    Mesh(reference.globeGeometry(), MeshMaterial(color: Color3.hex(0x164651))),
  );
  scene.add(
    Mesh(
      _graticule(reference),
      MeshMaterial(color: Color3.hex(0x36818b), unlit: true),
    ),
  );
  final marker = SphereGeometry(
    radius: 65000,
    widthSegments: 16,
    heightSegments: 10,
  );
  for (final coordinate in locations.values) {
    scene.add(
      Mesh(marker, MeshMaterial(color: Color3.hex(0xf2bd65), unlit: true))
        ..position.setFrom(
          reference.toEcef(
            Geodetic.degrees(coordinate.$1, coordinate.$2, 70000),
          ),
        ),
    );
  }
  return scene;
}

BufferGeometry _graticule(GeospatialReference reference) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  void band(bool latitude, double angle) {
    const segments = 144;
    final offset = positions.length ~/ 3;
    for (var i = 0; i <= segments; i++) {
      final along = latitude
          ? -math.pi + 2 * math.pi * i / segments
          : -math.pi / 2 + math.pi * i / segments;
      for (final side in [-1, 1]) {
        final lon = latitude ? along : angle + side * .0025;
        final lat = latitude ? angle + side * .0025 : along;
        final p = reference.toEcef(Geodetic(lon, lat, 12000));
        positions.addAll(p.storage);
        normals.addAll(reference.ellipsoid.surfaceNormal(p).storage);
      }
      if (i < segments) {
        final a = offset + i * 2;
        indices.addAll([a, a + 1, a + 2, a + 1, a + 3, a + 2]);
      }
    }
  }

  for (var lat = -60; lat <= 60; lat += 30) {
    band(true, lat * math.pi / 180);
  }
  for (var lon = -180; lon < 180; lon += 30) {
    band(false, lon * math.pi / 180);
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
}
