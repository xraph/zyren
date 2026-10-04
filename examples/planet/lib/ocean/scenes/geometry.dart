import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

final class OceanLabLocalGroup extends Group {
  final Mat4 transform;
  OceanLabLocalGroup(this.transform);
  @override
  Mat4 get localMatrix => transform;
}

Group oceanLabVessel() {
  final vessel = Group(name: 'procedural-research-vessel');
  final hull = vessel.add(
    Mesh(
      BoxGeometry(width: 3, height: 7, depth: 1.5),
      StandardMaterial(
        color: const Color3(.045, .13, .19),
        roughness: .32,
        metallic: .25,
      ),
    ),
  );
  hull.position = const Vec3(0, 0, -.1);
  vessel
      .add(
        Mesh(
          BoxGeometry(width: 2.7, height: 6.7, depth: .15),
          StandardMaterial(color: const Color3(.75, .73, .65), roughness: .75),
        ),
      )
      .position = const Vec3(
    0,
    0,
    .7,
  );
  vessel
      .add(
        Mesh(
          BoxGeometry(width: 1.8, height: 2.2, depth: 1.4),
          StandardMaterial(color: const Color3(.87, .9, .91), roughness: .3),
        ),
      )
      .position = const Vec3(
    0,
    1.2,
    1.45,
  );
  vessel
      .add(
        Mesh(
          BoxGeometry(width: 1.65, height: .04, depth: .65),
          StandardMaterial(
            color: const Color3(.025, .065, .09),
            roughness: .08,
            metallic: .4,
          ),
        ),
      )
      .position = const Vec3(
    0,
    2.32,
    1.6,
  );
  vessel
      .add(
        Mesh(
          BoxGeometry(width: .1, height: .1, depth: 2.1),
          StandardMaterial(
            color: const Color3(.65, .7, .73),
            metallic: .8,
            roughness: .2,
          ),
        ),
      )
      .position = const Vec3(
    0,
    1.3,
    3.1,
  );
  for (final x in [-1.4, 1.4]) {
    vessel
        .add(
          Mesh(
            BoxGeometry(width: .05, height: 5.4, depth: .05),
            StandardMaterial(color: const Color3(.7, .75, .78), metallic: .8),
          ),
        )
        .position = Vec3(
      x,
      -.3,
      1.2,
    );
  }
  return vessel;
}

BuoyancyHull oceanLabHull() => BuoyancyHull(
  vertices: [
    for (final z in [-.85, .65]) ...[
      Vec3(-1.5, -3.5, z),
      Vec3(1.5, -3.5, z),
      Vec3(1.5, 3.5, z),
      Vec3(-1.5, 3.5, z),
    ],
  ],
  indices: const [
    0,
    2,
    1,
    0,
    3,
    2,
    4,
    5,
    6,
    4,
    6,
    7,
    0,
    1,
    5,
    0,
    5,
    4,
    3,
    7,
    6,
    3,
    6,
    2,
    0,
    4,
    7,
    0,
    7,
    3,
    1,
    2,
    6,
    1,
    6,
    5,
  ],
);

BufferGeometry oceanLabTerrain(GeoScalarGrid grid, {Geodetic? origin}) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  final local = EastNorthUpFrame(origin ?? Geodetic(0, 0));
  for (var y = 0; y < grid.height; y++) {
    for (var x = 0; x < grid.width; x++) {
      final coordinate = Geodetic(
        grid.bounds.west + grid.bounds.width * x / (grid.width - 1),
        grid.bounds.south + grid.bounds.height * y / (grid.height - 1),
        grid.values[y * grid.width + x],
      );
      positions.addAll(
        local.toLocal(Ellipsoid.wgs84.toEcef(coordinate)).storage,
      );
      normals.addAll(const [0.0, 0.0, 1.0]);
      if (x < grid.width - 1 && y < grid.height - 1) {
        final a = y * grid.width + x, b = a + 1, c = a + grid.width, d = c + 1;
        indices.addAll([a, b, d, a, d, c]);
      }
    }
  }
  final geometry = BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
  return GeometryUtils.computeVertexNormals(geometry);
}
