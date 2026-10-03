import 'dart:async';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../geospatial_plugin.dart';
import 'sample.dart';
import 'time.dart';

enum GeoHeightDatum { ellipsoid, meanSeaLevel, terrain }

abstract interface class GeoHeightProvider {
  FutureOr<GeoSample<double>> convert(
    Geodetic coordinate, {
    required GeoHeightDatum from,
    required GeoHeightDatum to,
    required GeoInstant time,
  });
}

/// Ellipsoid heights pass through. Other datums require a geoid/terrain provider.
final class GeoEllipsoidHeightProvider implements GeoHeightProvider {
  final String sourceRevision;
  const GeoEllipsoidHeightProvider({required this.sourceRevision});
  @override
  GeoSample<double> convert(
    Geodetic coordinate, {
    required GeoHeightDatum from,
    required GeoHeightDatum to,
    required GeoInstant time,
  }) {
    if (from != GeoHeightDatum.ellipsoid || to != GeoHeightDatum.ellipsoid) {
      return GeoSample(availability: GeoSampleAvailability.unavailable);
    }
    return GeoSample(
      availability: GeoSampleAvailability.available,
      value: coordinate.height,
      frameId: 'body-fixed',
      frameRevision: 0,
      sourceRevision: sourceRevision,
      units: 'm',
      time: time,
      age: Duration.zero,
      error: 0,
    );
  }
}

/// A metre-scale local east/north/up frame over a body-fixed ellipsoid.
final class GeoWorldFrame {
  final GeospatialReference reference;
  final String id;
  Geodetic _origin;
  late EastNorthUpFrame _frame = reference.localFrame(_origin);
  int _revision = 0;
  bool _closed = false, _rebasing = false;
  final _rebases = StreamController<GeoWorldRebase>.broadcast(sync: true);
  GeoWorldFrame({
    required this.reference,
    required Geodetic origin,
    this.id = 'local-enu',
  }) : _origin = origin {
    if (id.trim().isEmpty) throw ArgumentError('A world frame needs an ID.');
  }
  int get revision => _revision;
  Geodetic get origin => _origin;
  Stream<GeoWorldRebase> get rebases => _rebases.stream;
  Vec3 toLocal(Vec3 ecef) => _frame.toLocal(ecef);
  Vec3 toEcef(Vec3 local) => _frame.toEcef(local);
  Vec3 vectorToLocal(Vec3 ecef) {
    if (!ecef.isFinite) throw ArgumentError('Frame vectors must be finite.');
    return Vec3(
      ecef.dot(_frame.east),
      ecef.dot(_frame.north),
      ecef.dot(_frame.up),
    );
  }

  Vec3 vectorToEcef(Vec3 local) {
    if (!local.isFinite) throw ArgumentError('Frame vectors must be finite.');
    return _frame.east * local.x + _frame.north * local.y + _frame.up * local.z;
  }

  GeoWorldRebase rebase(Geodetic origin) {
    if (_closed || _rebasing) {
      throw StateError('World frame is closed or already rebasing.');
    }
    final next = reference.localFrame(origin);
    final event = GeoWorldRebase(
      id,
      _revision,
      _revision + 1,
      next.matrix.inverted() * _frame.matrix,
    );
    _rebasing = true;
    try {
      _rebases.add(event);
      _origin = origin;
      _frame = next;
      _revision++;
      return event;
    } finally {
      _rebasing = false;
    }
  }

  Future<void> dispose() {
    if (_rebasing) {
      throw StateError('Cannot close a frame while publishing a rebase.');
    }
    _closed = true;
    return _rebases.close();
  }
}

final class GeoWorldRebase {
  final String frameId;
  final int previousRevision, revision;
  final Mat4 oldToNew;
  const GeoWorldRebase(
    this.frameId,
    this.previousRevision,
    this.revision,
    this.oldToNew,
  );
  Vec3 transformPosition(Vec3 value) => _transform(value, 1);
  Vec3 transformVector(Vec3 value) => _transform(value, 0);
  Vec3 _transform(Vec3 value, double w) {
    if (!value.isFinite) {
      throw ArgumentError('Frame transforms need finite inputs.');
    }
    final m = oldToNew.storage;
    return Vec3(
      m[0] * value.x + m[4] * value.y + m[8] * value.z + m[12] * w,
      m[1] * value.x + m[5] * value.y + m[9] * value.z + m[13] * w,
      m[2] * value.x + m[6] * value.y + m[10] * value.z + m[14] * w,
    );
  }
}
