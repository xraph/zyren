import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../queries/query.dart';
import 'clipping.dart';
import 'drag.dart';
import 'probes.dart';

/// Symmetric positive-semidefinite inverse inertia in world axes, 1/(kg m^2).
/// Zero eigenvalues permit locked axes. No renderer matrix layout is involved.
final class BuoyancyInverseInertia {
  final double xx, yy, zz, xy, xz, yz;
  BuoyancyInverseInertia(
    this.xx,
    this.yy,
    this.zz, {
    this.xy = 0,
    this.xz = 0,
    this.yz = 0,
  }) {
    final values = [xx, yy, zz, xy, xz, yz];
    if (values.any((v) => !v.isFinite || v.abs() > 1e12) ||
        xx < 0 ||
        yy < 0 ||
        zz < 0) {
      throw ArgumentError(
        'Inverse inertia must be finite and positive semidefinite.',
      );
    }
    final scale = values.map((v) => v.abs()).reduce(math.max);
    if (scale == 0) return;
    final a = xx / scale,
        b = yy / scale,
        c = zz / scale,
        d = xy / scale,
        e = xz / scale,
        f = yz / scale;
    if (a * b - d * d < -1e-14 ||
        a * c - e * e < -1e-14 ||
        b * c - f * f < -1e-14 ||
        a * b * c + 2 * d * e * f - a * f * f - b * e * e - c * d * d <
            -1e-14) {
      throw ArgumentError('Inverse inertia must be positive semidefinite.');
    }
  }
  Vec3 apply(Vec3 v) => Vec3(
    xx * v.x + xy * v.y + xz * v.z,
    xy * v.x + yy * v.y + yz * v.z,
    xz * v.x + yz * v.y + zz * v.z,
  );
}

/// Immutable authoritative body snapshot in [frame]'s local world axes.
/// Create a new snapshot after each simulation step or frame rebase.
final class BuoyancyBodyState {
  final GeoWorldFrame frame;
  final int frameRevision;
  final GeoInstant time;
  final Vec3 position, centerOfMass, linearVelocity, angularVelocity;
  final Quat rotation;
  final double mass;
  final BuoyancyInverseInertia inverseInertia;
  final _queries = <BuoyancyShape, List<OceanQuery>>{};
  BuoyancyBodyState({
    required this.frame,
    required this.time,
    required this.position,
    required Quat rotation,
    required this.centerOfMass,
    required this.linearVelocity,
    required this.angularVelocity,
    required this.mass,
    required this.inverseInertia,
  }) : frameRevision = frame.revision,
       rotation = rotation.normalized() {
    if (!mass.isFinite ||
        mass <= 0 ||
        mass > 1e15 ||
        [
          position,
          centerOfMass,
          linearVelocity,
          angularVelocity,
        ].any((v) => !v.isFinite || v.length > 1e12)) {
      throw ArgumentError(
        'Body state must be finite with positive bounded mass.',
      );
    }
  }
  Vec3 pointToWorld(Vec3 local) => position + rotation.rotate(local);
  Vec3 velocityAt(Vec3 point) =>
      linearVelocity + angularVelocity.cross(point - centerOfMass);
  void _check() {
    if (frame.revision != frameRevision) {
      throw StateError('Body snapshot predates the current world frame.');
    }
  }
}

final class BuoyancyPointLoad {
  final Vec3 position, buoyancy, drag;
  final double volume;
  const BuoyancyPointLoad({
    required this.position,
    required this.buoyancy,
    required this.drag,
    required this.volume,
  });
  Vec3 get force => buoyancy + drag;
}

final class BuoyancyDiagnostics {
  final int sampleCount;
  final double minimumVolume, maximumVolume, maximumCellDiameter, dragScale;
  final double maxHeightErrorMetres,
      maxNormalErrorRadians,
      maxVelocityErrorMetresPerSecond;

  /// Unknown without a surface-curvature provider. Plane intervals below do not
  /// bound the error from approximating a curved surface by one plane per cell.
  double? get surfaceCurvatureErrorMetres => null;
  const BuoyancyDiagnostics({
    required this.sampleCount,
    required this.minimumVolume,
    required this.maximumVolume,
    required this.maximumCellDiameter,
    required this.dragScale,
    required this.maxHeightErrorMetres,
    required this.maxNormalErrorRadians,
    required this.maxVelocityErrorMetresPerSecond,
  });
}

final class BuoyancyLoads {
  final List<BuoyancyPointLoad> points;
  final Vec3 intrinsicTorque, totalForce, totalTorque;
  final double displacedVolume;
  final Vec3? centerOfBuoyancy;
  final BuoyancyDiagnostics diagnostics;
  BuoyancyLoads._(
    List<BuoyancyPointLoad> points,
    this.intrinsicTorque,
    this.displacedVolume,
    this.centerOfBuoyancy,
    this.diagnostics,
    Vec3 centerOfMass,
  ) : points = List.unmodifiable(points),
      totalForce = points.fold(Vec3.zero, (sum, p) => sum + p.force),
      totalTorque = points.fold(
        intrinsicTorque,
        (sum, p) => sum + (p.position - centerOfMass).cross(p.force),
      );
}

final class BuoyancySolver {
  final BuoyancyDrag drag;
  final double maxHeightErrorMetres,
      maxNormalErrorRadians,
      maxVelocityErrorMetresPerSecond;
  BuoyancySolver({
    BuoyancyDrag? drag,
    this.maxHeightErrorMetres = .01,
    this.maxNormalErrorRadians = .01,
    this.maxVelocityErrorMetresPerSecond = .1,
  }) : drag = drag ?? BuoyancyDrag() {
    if ([
          maxHeightErrorMetres,
          maxNormalErrorRadians,
          maxVelocityErrorMetresPerSecond,
        ].any((v) => !v.isFinite || v < 0) ||
        maxNormalErrorRadians > math.pi / 2) {
      throw ArgumentError('Invalid buoyancy sample error limits.');
    }
  }

  /// Query objects are stable, ordered sample IDs for this exact body/shape pair.
  /// Pass these objects to OceanSampler; it returns them unchanged in each sample.
  List<OceanQuery> queries(BuoyancyBodyState body, BuoyancyShape shape) {
    body._check();
    return body._queries.putIfAbsent(
      shape,
      () => List.unmodifiable([
        for (final point in shape.quadraturePoints)
          OceanQuery(body.frame.toEcef(body.pointToWorld(point)), body.time),
      ]),
    );
  }

  BuoyancyLoads solve(
    BuoyancyBodyState body,
    BuoyancyShape shape,
    List<OceanSample> samples, {
    required Vec3 gravity,
    required double density,
    required double stepSeconds,
  }) {
    body._check();
    if (!gravity.isFinite ||
        gravity.length > 1e6 ||
        !density.isFinite ||
        density <= 0 ||
        density > 1e6 ||
        !stepSeconds.isFinite ||
        stepSeconds <= 0 ||
        stepSeconds > 1) {
      throw ArgumentError(
        'Use finite gravity, density in (0,1e6] and step seconds in (0,1].',
      );
    }
    final expected = queries(body, shape);
    if (samples.length != expected.length) {
      throw ArgumentError('Buoyancy sample count does not match the shape.');
    }
    var heightError = 0.0, normalError = 0.0, velocityError = 0.0;
    // Admit the complete batch before calculating any load.
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i], v = s.value, a = s.accuracy;
      if (!identical(s.query, expected[i]) ||
          !s.available ||
          v == null ||
          a == null ||
          s.frameId != body.frame.id ||
          s.frameRevision != body.frameRevision ||
          s.evaluatedTime != body.time ||
          s.age != Duration.zero ||
          s.seaStateRevision.isEmpty ||
          s.coverageRevision.isEmpty ||
          s.seaStateRevision != samples.first.seaStateRevision ||
          s.coverageRevision != samples.first.coverageRevision ||
          [
            v.positionLocal,
            v.normalLocal,
            v.velocityLocal,
            v.positionEcef,
            v.normalEcef,
            v.velocityEcef,
          ].any((p) => !p.isFinite) ||
          (v.normalLocal.length2 - 1).abs() > 1e-8 ||
          [
            a.heightErrorMetres,
            a.normalErrorRadians,
            a.velocityErrorMetresPerSecond,
            a.rootRadiusMetres,
          ].any((e) => !e.isFinite || e < 0) ||
          a.heightErrorMetres > maxHeightErrorMetres ||
          a.normalErrorRadians > maxNormalErrorRadians ||
          a.velocityErrorMetresPerSecond > maxVelocityErrorMetresPerSecond ||
          body.frame.toLocal(v.positionEcef).distanceTo(v.positionLocal) >
              1e-6 ||
          body.frame.vectorToLocal(v.normalEcef).distanceTo(v.normalLocal) >
              1e-8 ||
          body.frame.vectorToLocal(v.velocityEcef).distanceTo(v.velocityLocal) >
              1e-6) {
        throw ArgumentError(
          'Sample $i is unavailable, mismatched, stale or outside buoyancy error limits. '
          'Query failure: ${s.failure?.name ?? "none"}; '
          'height error: ${a?.heightErrorMetres}; normal error: ${a?.normalErrorRadians}; '
          'velocity error: ${a?.velocityErrorMetresPerSecond}.',
        );
      }
      heightError = math.max(heightError, a.heightErrorMetres);
      normalError = math.max(normalError, a.normalErrorRadians);
      velocityError = math.max(velocityError, a.velocityErrorMetresPerSecond);
    }
    final wet = <(BuoyancyVolume, Vec3)>[];
    var total = 0.0, minimum = 0.0, maximum = 0.0;
    var moment = Vec3.zero;
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i].value!, a = samples[i].accuracy!;
      final n = v.normalLocal, point = v.positionLocal;
      late BuoyancyVolume volume;
      late double lower, upper;
      switch (shape) {
        case BuoyancyProbes():
          final probe = shape.probes[i],
              center = body.pointToWorld(probe.localCenter);
          final h = probe.radius - (center - point).dot(n),
              weight = shape.weight(i);
          // Rotation uncertainty displaces the plane by at most 2 sin(theta/2)
          // times distance from its anchor to any point in this integration cell.
          final error =
              a.heightErrorMetres +
              a.rootRadiusMetres +
              2 *
                  math.sin(a.normalErrorRadians / 2) *
                  (center.distanceTo(point) + probe.radius);
          final amount = submergedSphereVolume(probe.radius, h) * weight;
          volume = BuoyancyVolume(
            amount,
            amount == 0
                ? null
                : center + n * submergedSphereCentroidOffset(probe.radius, h),
          );
          lower = submergedSphereVolume(probe.radius, h - error) * weight;
          upper = submergedSphereVolume(probe.radius, h + error) * weight;
        case BuoyancyHull():
          final local = shape.cells[i];
          final cell = BuoyancyTetrahedron(
            body.pointToWorld(local.a),
            body.pointToWorld(local.b),
            body.pointToWorld(local.c),
            body.pointToWorld(local.d),
          );
          final radius = cell.vertices
              .map((p) => p.distanceTo(point))
              .reduce(math.max);
          final error =
              a.heightErrorMetres +
              a.rootRadiusMetres +
              2 * math.sin(a.normalErrorRadians / 2) * radius;
          volume = cell.clip(point, n);
          lower = error == 0
              ? volume.volume
              : cell.clip(point - n * error, n).volume;
          upper = error == 0
              ? volume.volume
              : cell.clip(point + n * error, n).volume;
      }
      minimum += lower;
      maximum += upper;
      total += volume.volume;
      if (volume.volume > 0) {
        moment =
            moment + (volume.centroid! - body.centerOfMass) * volume.volume;
        wet.add((volume, v.velocityLocal));
      }
    }
    final forces = <Vec3>[], relatives = <Vec3>[];
    var force = Vec3.zero, torque = Vec3.zero, power = 0.0;
    for (final (volume, waterVelocity) in wet) {
      final relative = body.velocityAt(volume.centroid!) - waterVelocity;
      final f = drag.force(relative, volume.volume);
      forces.add(f);
      relatives.add(relative);
      force = force + f;
      torque = torque + (volume.centroid! - body.centerOfMass).cross(f);
      power += f.dot(relative);
    }
    final intrinsic = body.angularVelocity * (-drag.angular * total);
    torque = torque + intrinsic;
    power += intrinsic.dot(body.angularVelocity);
    final dv = force / body.mass, dw = body.inverseInertia.apply(torque);
    var scale = 1.0;
    for (var i = 0; i < wet.length; i++) {
      final relative = relatives[i], speed2 = relative.length2;
      final change = dv + dw.cross(wet[i].$1.centroid! - body.centerOfMass);
      final deceleration = -relative.dot(change);
      if (speed2 > 0 && deceleration > 0) {
        scale = math.min(scale, speed2 / (stepSeconds * deceleration));
      }
    }
    final angularDeceleration = -body.angularVelocity.dot(dw);
    if (angularDeceleration > 0) {
      scale = math.min(
        scale,
        body.angularVelocity.length2 / (stepSeconds * angularDeceleration),
      );
    }
    // Common scaling includes all point interactions and intrinsic torque.
    // This minimizes the frozen-flow work quadratic before it can add energy.
    final quadratic = force.dot(dv) + torque.dot(dw);
    if (quadratic > 0) {
      scale = math.min(scale, math.max(0, -power / (stepSeconds * quadratic)));
    }
    if (!scale.isFinite ||
        !force.isFinite ||
        !torque.isFinite ||
        !power.isFinite ||
        !quadratic.isFinite) {
      throw ArgumentError('Buoyancy drag exceeds finite arithmetic limits.');
    }
    final points = [
      for (var i = 0; i < wet.length; i++)
        BuoyancyPointLoad(
          position: wet[i].$1.centroid!,
          buoyancy: -gravity * (density * wet[i].$1.volume),
          drag: forces[i] * scale,
          volume: wet[i].$1.volume,
        ),
    ];
    return BuoyancyLoads._(
      points,
      intrinsic * scale,
      total,
      total == 0 ? null : body.centerOfMass + moment / total,
      BuoyancyDiagnostics(
        sampleCount: samples.length,
        minimumVolume: minimum,
        maximumVolume: maximum,
        maximumCellDiameter: shape.maximumCellDiameter,
        dragScale: scale,
        maxHeightErrorMetres: heightError,
        maxNormalErrorRadians: normalError,
        maxVelocityErrorMetresPerSecond: velocityError,
      ),
      body.centerOfMass,
    );
  }
}
