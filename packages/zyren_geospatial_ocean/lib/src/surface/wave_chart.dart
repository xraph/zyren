import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'cube_patch.dart';

/// A fixed chart's metre coordinates and derivatives along the local tangent basis.
final class OceanChartCoordinate {
  final int id, seed;
  final double u,
      v,
      weight,
      weightEast,
      weightNorth,
      uEast,
      uNorth,
      vEast,
      vNorth;
  const OceanChartCoordinate._(
    this.id,
    this.seed,
    this.u,
    this.v,
    this.weight,
    this.weightEast,
    this.weightNorth,
    this.uEast,
    this.uNorth,
    this.vEast,
    this.vNorth,
  );
}

final class OceanChartValue {
  final double value, uDerivative, vDerivative;
  const OceanChartValue(this.value, this.uDerivative, this.vDerivative);
}

final class OceanChartBlend {
  final double value, eastDerivative, northDerivative;
  const OceanChartBlend(this.value, this.eastDerivative, this.northDerivative);
}

final class OceanChartPoint {
  final Vec3 position, normal, east, north, normalEast, normalNorth;
  final List<OceanChartCoordinate> coordinates;
  OceanChartPoint._(
    this.position,
    this.normal,
    this.east,
    this.north,
    this.normalEast,
    this.normalNorth,
    Iterable<OceanChartCoordinate> coordinates,
  ) : coordinates = List.unmodifiable(coordinates);
  OceanChartBlend blend(
    OceanChartValue Function(OceanChartCoordinate) evaluate,
  ) {
    var value = 0.0, e = 0.0, n = 0.0;
    for (final c in coordinates) {
      final f = evaluate(c);
      if (!f.value.isFinite ||
          !f.uDerivative.isFinite ||
          !f.vDerivative.isFinite) {
        throw ArgumentError('Chart samples must be finite.');
      }
      value += c.weight * f.value;
      e +=
          c.weightEast * f.value +
          c.weight * (f.uDerivative * c.uEast + f.vDerivative * c.vEast);
      n +=
          c.weightNorth * f.value +
          c.weight * (f.uDerivative * c.uNorth + f.vDerivative * c.vNorth);
    }
    if (!value.isFinite || !e.isFinite || !n.isFinite) {
      throw StateError('Chart blend overflowed.');
    }
    return OceanChartBlend(value, e, n);
  }
}

/// Six fixed world charts. Coordinates never depend on render patches or cameras.
/// The seed mapping is version 1 and uses unsigned 32-bit avalanche arithmetic.
final class OceanWaveCharts {
  final Ellipsoid ellipsoid;
  final int seed;
  OceanWaveCharts({this.ellipsoid = Ellipsoid.wgs84, required this.seed}) {
    validateOceanEllipsoid(ellipsoid);
    if (seed < 0 || seed > 0xffffffff) {
      throw ArgumentError('Chart seed must fit uint32.');
    }
  }
  int seedFor(int id) {
    _validateId(id);
    var x = (seed ^ ((id + 1) * 0x9e3779b9)) & 0xffffffff;
    x = ((x ^ (x >>> 16)) * 0x85ebca6b) & 0xffffffff;
    x = ((x ^ (x >>> 13)) * 0xc2b2ae35) & 0xffffffff;
    return (x ^ (x >>> 16)) & 0xffffffff;
  }

  OceanChartPoint atSurface(Vec3 position) {
    final inverse = ellipsoid.reciprocalRadiiSquared;
    Vec3 apply(Vec3 p) =>
        Vec3(p.x * inverse.x, p.y * inverse.y, p.z * inverse.z);
    final weighted = apply(position), surface = position.dot(weighted);
    if (!position.isFinite || !surface.isFinite || (surface - 1).abs() > 1e-9) {
      throw ArgumentError(
        'Wave charts require a point on the declared ellipsoid surface.',
      );
    }
    final normal = weighted.normalized(),
        horizontal = Vec3(-normal.y, normal.x, 0);
    final east = horizontal.length2 == 0
        ? const Vec3(0, 1, 0)
        : horizontal.normalized();
    final north = normal.cross(east).normalized();
    // Differential of normalize(A^-1 p), valid for any positive triaxial ellipsoid.
    Vec3 dn(Vec3 tangent) {
      final a = apply(tangent);
      return (a - normal * normal.dot(a)) / weighted.length;
    }

    final ne = dn(east), nn = dn(north);
    final raw = <(int, double, double, double)>[];
    var sum = 0.0, se = 0.0, sn = 0.0;
    for (var id = 0; id < 6; id++) {
      final axis = oceanCubeFaces[id].normal, a = normal.dot(axis) - .25;
      if (a <= 0) continue;
      final weight = a * a * a * a,
          e = 4 * a * a * a * axis.dot(ne),
          n = 4 * a * a * a * axis.dot(nn);
      raw.add((id, weight, e, n));
      sum += weight;
      se += e;
      sn += n;
    }
    return OceanChartPoint._(position, normal, east, north, ne, nn, [
      for (final (id, w, e, n) in raw)
        OceanChartCoordinate._(
          id,
          seedFor(id),
          position.dot(oceanCubeFaces[id].u),
          position.dot(oceanCubeFaces[id].v),
          w / sum,
          (e * sum - w * se) / (sum * sum),
          (n * sum - w * sn) / (sum * sum),
          east.dot(oceanCubeFaces[id].u),
          north.dot(oceanCubeFaces[id].u),
          east.dot(oceanCubeFaces[id].v),
          north.dot(oceanCubeFaces[id].v),
        ),
    ]);
  }

  /// Conservative chart set for an entire cube patch, including overlap margins.
  Set<int> chartsForPatch(OceanPatchId patch) {
    final bounds = patch.bounds(ellipsoid),
        inv = ellipsoid.reciprocalRadiiSquared;
    final c = Vec3(
      bounds.center.x * inv.x,
      bounds.center.y * inv.y,
      bounds.center.z * inv.z,
    );
    final radius =
        bounds.radius / (ellipsoid.minimumRadius * ellipsoid.minimumRadius);
    if (radius >= c.length) return Set.unmodifiable({0, 1, 2, 3, 4, 5});
    final normal = c.normalized(), angle = math.asin(radius / c.length);
    return Set.unmodifiable({
      for (var id = 0; id < 6; id++)
        if (math.acos(normal.dot(oceanCubeFaces[id].normal).clamp(-1, 1)) -
                angle <
            math.acos(.25))
          id,
    });
  }
}

void _validateId(int id) {
  if (id < 0 || id >= 6) throw ArgumentError('Unknown ocean chart identity.');
}

Set<int> _ids(Iterable<int> input) {
  final result = <int>{};
  var count = 0;
  for (final id in input) {
    if (++count > 6) {
      throw ArgumentError('At most six chart IDs may be supplied.');
    }
    _validateId(id);
    result.add(id);
  }
  return result;
}

/// Residency admission is atomic. Physics leases survive visual culling.
final class OceanChartResidency {
  final int maxCharts;
  Set<int> _visible = {};
  final _physics = <Object, Set<int>>{};
  OceanChartResidency({this.maxCharts = 6}) {
    if (maxCharts < 1 || maxCharts > 6) {
      throw ArgumentError('Chart budget must be 1..6.');
    }
  }
  Set<int> get residentIds => Set.unmodifiable({
    ..._visible,
    for (final ids in _physics.values) ...ids,
  });
  void setVisible(Iterable<int> ids) {
    final candidate = _ids(ids);
    _admit({...candidate, for (final ids in _physics.values) ...ids});
    _visible = candidate;
  }

  OceanChartLease acquirePhysics(Iterable<int> ids) {
    final candidate = _ids(ids), key = Object();
    _admit({...residentIds, ...candidate});
    _physics[key] = candidate;
    return OceanChartLease._(() => _physics.remove(key));
  }

  void _admit(Set<int> ids) {
    if (ids.length > maxCharts) {
      throw StateError('Ocean chart residency exceeds its budget.');
    }
  }
}

final class OceanChartLease {
  void Function()? _release;
  OceanChartLease._(this._release);
  void close() {
    _release?.call();
    _release = null;
  }
}
