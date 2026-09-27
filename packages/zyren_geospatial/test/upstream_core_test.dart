import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

List<double> doubles(dynamic values) =>
    (values as List).map((v) => (v as num).toDouble()).toList();
Vec3 vector(dynamic values) => Vec3.array(doubles(values));
void nearVector(Vec3 actual, dynamic expected, double tolerance) =>
    expect(actual.distanceTo(vector(expected)), lessThanOrEqualTo(tolerance));
void nearList(List<double> actual, dynamic expected, double tolerance) {
  final values = doubles(expected);
  expect(actual.length, values.length);
  for (var i = 0; i < values.length; i++) {
    expect(actual[i], closeTo(values[i], tolerance), reason: 'component $i');
  }
}

void main() {
  final fixtures =
      jsonDecode(File('test/fixtures/upstream_core.json').readAsStringSync())
          as Map<String, dynamic>;

  test(
    '200 upstream geodesy cases cover triaxial bodies, poles and orbital heights',
    () {
      for (final row in fixtures['geodesy']) {
        final radii = doubles(row['radii']);
        final ellipsoid = Ellipsoid(radii[0], radii[1], radii[2]);
        final coordinate = Geodetic.fromList(doubles(row['coordinate']));
        final position = coordinate.toEcef(ellipsoid: ellipsoid);
        nearVector(position, row['position'], 2e-8);
        nearVector(ellipsoid.projectOnSurface(position), row['surface'], 2e-8);
        nearVector(ellipsoid.surfaceNormal(position), row['normal'], 1e-14);
        final inverse = ellipsoid.fromEcef(position),
            expected = doubles(row['inverse']);
        expect(inverse.longitude, closeTo(expected[0], 1e-12));
        // Upstream asin loses 1.49e-8 radians at a pole; atan2 retains it.
        final latitudeTolerance = coordinate.latitude.abs() == math.pi / 2
            ? 2e-8
            : 1e-12;
        expect(inverse.latitude, closeTo(expected[1], latitudeTolerance));
        expect(inverse.height, closeTo(expected[2], 2e-8));
        final basis = ellipsoid.eastNorthUpVectors(position);
        nearVector(basis.east, row['east'], 1e-12);
        nearVector(basis.north, row['north'], 1e-12);
        nearVector(basis.up, row['up'], 1e-12);
        nearList(
          ellipsoid.eastNorthUpFrame(position).storage,
          row['enu'],
          2e-8,
        );
        nearList(
          ellipsoid.northUpEastFrame(position).storage,
          row['nue'],
          2e-8,
        );
      }
    },
  );

  test(
    'near-center radial projection follows upstream; center remains undefined',
    () {
      for (final row in fixtures['projection']) {
        nearVector(
          Ellipsoid.wgs84.projectOnSurface(vector(row['position'])),
          row['surface'],
          1e-8,
        );
      }
      expect(
        () => Ellipsoid.wgs84.projectOnSurface(Vec3.zero),
        throwsArgumentError,
      );
      expect(
        () => Ellipsoid.wgs84.projectOnSurface(Vec3.one, centerTolerance: -1),
        throwsArgumentError,
      );
    },
  );

  test('ellipsoid derived values, horizon and osculating centers', () {
    final ellipsoid = Ellipsoid.wgs84;
    expect(ellipsoid.flattening, closeTo(1 / 298.257223563, 1e-15));
    expect(ellipsoid.eccentricitySquared, closeTo(.0066943799901413165, 1e-15));
    expect(ellipsoid.minimumRadius, ellipsoid.z);
    expect(ellipsoid.maximumRadius, ellipsoid.x);
    for (final row in fixtures['ellipsoidExtras']) {
      nearVector(
        ellipsoid.osculatingSphereCenter(
          vector(row['position']),
          (row['radius'] as num).toDouble(),
        ),
        row['center'],
        1e-8,
      );
      nearVector(
        ellipsoid.normalAtHorizon(
          vector(row['position']),
          vector(row['direction']),
        ),
        row['horizon'],
        1e-12,
      );
    }
    expect(
      () => Ellipsoid(3, 2, 1).osculatingSphereCenter(Vec3.one, 1),
      throwsArgumentError,
    );
    final pole = ellipsoid.eastNorthUpVectors(Vec3(0, 0, ellipsoid.z));
    expect(pole.east.cross(pole.north), pole.up);
  });

  test('raw longitude and explicit normalization retain source semantics', () {
    expect(Geodetic(math.pi, 0).longitude, math.pi);
    expect(Geodetic(-5 * math.pi, 0).normalized().longitude, -3 * math.pi);
    expect(Geodetic(5 * math.pi, 0).normalized().longitude, 5 * math.pi);
    final original = Geodetic(1, .5, 12);
    expect(original.copyWith(height: 13).toList(), [1, .5, 13]);
    expect(original, Geodetic.fromList([1, .5, 12]));
  });

  test(
    '60 upstream geographic tile cases preserve source boundaries and quirks',
    () {
      for (final row in fixtures['tiling']) {
        final rectangle = GeographicRectangle.fromList(doubles(row['bounds']));
        final scheme = TilingScheme(rectangle: rectangle);
        expect(rectangle.width, closeTo(row['width'], 1e-14));
        expect(rectangle.height, closeTo(row['height'], 1e-14));
        for (final point in row['points']) {
          final xy = doubles(point['xy']);
          nearList(
            rectangle.at(xy[0], xy[1]).toList(),
            point['coordinate'],
            1e-14,
          );
        }
        for (final item in row['tiles']) {
          final tile = scheme.getTile(
            Geodetic.fromList(doubles(item['coordinate'])),
            item['z'],
          );
          expect(tile.toList(), item['tile']);
          nearList(
            scheme.getRectangle(tile).toList(),
            item['rectangle'],
            1e-14,
          );
          final size = scheme.getSize(item['z']);
          expect([size.width, size.height], item['size']);
        }
      }
      final scheme = TilingScheme();
      expect(
        scheme.getTile(Geodetic(-math.pi, -math.pi / 2), 1),
        TileCoordinate(0, 0, 1),
      );
      expect(
        scheme.getTile(Geodetic(math.pi, math.pi / 2), 1),
        TileCoordinate(3, 1, 1),
      );
      expect(() => scheme.getSize(-1), throwsRangeError);
      expect(() => scheme.getSize(31), throwsRangeError);
      expect(() => TilingScheme(width: 0), throwsArgumentError);
    },
  );

  test('upstream descendant order and negative-coordinate parent floor', () {
    for (final row in fixtures['descendants']) {
      final tile = TileCoordinate.fromList((row['tile'] as List).cast<int>());
      expect(tile.parent.toList(), row['parent']);
      for (final item in row['levels']) {
        expect(
          tile.traverseChildren(item['depth']).map((c) => c.toList()).toList(),
          item['children'],
        );
      }
    }
    expect(
      () => TileCoordinate(0, 0, 0).traverseChildren(-1).toList(),
      throwsRangeError,
    );
  });

  test('24 upstream camera decompositions match eye, orientation and roll', () {
    for (final row in fixtures['views']) {
      final input = doubles(row['input']);
      final view = PointOfView(
        distance: input[0],
        heading: input[1],
        pitch: input[2],
        roll: input[3],
      );
      final pose = view.decompose(vector(row['target']));
      nearVector(pose.position, row['eye'], 1e-8);
      nearVector(pose.surfaceUp, row['surfaceUp'], 1e-12);
      nearVector(pose.up, row['worldUp'], 1e-10);
      final expected = doubles(row['quaternion']);
      final q = pose.quaternion;
      // q and -q encode the same rotation.
      expect(
        (q.x * expected[0] +
                q.y * expected[1] +
                q.z * expected[2] +
                q.w * expected[3])
            .abs(),
        closeTo(1, 1e-12),
      );
      final camera = PerspectiveCamera(far: 1e8);
      pose.applyTo(camera);
      camera.viewProjection(1);
      final recovered = PointOfView.fromCamera(camera)!;
      // Upstream unprojects a world-space point; subtraction at Earth scale
      // differs by up to 3.4 micrometers from zyren's target direction.
      nearVector(recovered.target, row['hit'], 5e-6);
      final inverse = doubles(row['inverse']);
      expect(recovered.view.distance, closeTo(inverse[0], 5e-6));
      nearList(
        [recovered.view.heading, recovered.view.pitch, recovered.view.roll],
        inverse.sublist(1),
        2e-8,
      );
    }
  });

  test('point of view clamps and sky misses', () {
    final view = PointOfView(distance: -2, pitch: math.pi);
    expect(view.distance, 1e-6);
    expect(view.pitch, math.pi / 2 - 1e-6);
    final camera = PerspectiveCamera(
      position: Vec3(1e7, 0, 0),
      target: Vec3(2e7, 0, 0),
    );
    expect(PointOfView.fromCamera(camera), isNull);
    expect(() => PointOfView(heading: double.nan), throwsArgumentError);
  });

  test(
    'vertical camera extraction has a defined zero roll at the horizon singularity',
    () {
      final camera = PerspectiveCamera(
        position: Vec3(6379137, 0, 0),
        target: Vec3(6378137, 0, 0),
      );
      final result = PointOfView.fromCamera(camera)!;
      expect(result.view.distance, closeTo(1000, 1e-8));
      expect(result.view.pitch, -math.pi / 2 + PointOfView.epsilon);
      expect(result.view.roll, 0);
    },
  );
}
