import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'hull_test.dart' show boxHull;

GeoWorldFrame forceFrame() => GeoWorldFrame(
  reference: const GeospatialReference(),
  origin: Geodetic(0, 0),
);
final forceTime = GeoInstant(tick: 10, hz: 60, epoch: DateTime.utc(2026));
BuoyancyBodyState forceBody(
  GeoWorldFrame frame, {
  Vec3 position = Vec3.zero,
  Quat rotation = Quat.identity,
  Vec3? centerOfMass,
  Vec3 velocity = Vec3.zero,
  Vec3 angularVelocity = Vec3.zero,
  double mass = 4000,
}) => BuoyancyBodyState(
  frame: frame,
  time: forceTime,
  position: position,
  rotation: rotation,
  centerOfMass: centerOfMass ?? position,
  linearVelocity: velocity,
  angularVelocity: angularVelocity,
  mass: mass,
  inverseInertia: BuoyancyInverseInertia(1 / mass, 1 / mass, 1 / mass),
);
List<OceanSample> planeSamples(
  BuoyancySolver solver,
  BuoyancyBodyState body,
  BuoyancyShape shape, {
  Vec3 normal = const Vec3(0, 0, 1),
  Vec3 waterVelocity = Vec3.zero,
  double Function(Vec3)? height,
  double error = 0,
}) => [
  for (final q in solver.queries(body, shape))
    (() {
      final point = body.frame.toLocal(q.positionEcef);
      final surface = height != null
          ? Vec3(point.x, point.y, height(point))
          : point - normal * point.dot(normal);
      return OceanSample(
        query: q,
        failure: null,
        value: OceanSurfaceValue(
          positionLocal: surface,
          normalLocal: normal,
          velocityLocal: waterVelocity,
          positionEcef: body.frame.toEcef(surface),
          materialEcef: body.frame.toEcef(surface),
          normalEcef: body.frame.vectorToEcef(normal),
          velocityEcef: body.frame.vectorToEcef(waterVelocity),
          height: surface.z,
        ),
        accuracy: OceanSurfaceAccuracy(error, 0, 0, 0),
        seaStateRevision: 'sea',
        coverageRevision: 'wet',
        frameId: body.frame.id,
        frameRevision: body.frameRevision,
        evaluatedTime: body.time,
        age: Duration.zero,
        residual: 0,
      );
    })(),
];
const gravity = Vec3(0, 0, -9.81);
void main() {
  test(
    'half box floats, overload sinks, dry and zero gravity are explicit',
    () {
      final frame = forceFrame(), solver = BuoyancySolver(), shape = boxHull();
      final body = forceBody(frame);
      final loads = solver.solve(
        body,
        shape,
        planeSamples(solver, body, shape),
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(loads.displacedVolume, closeTo(4, 1e-12));
      expect((loads.totalForce + gravity * body.mass).length, lessThan(1e-9));
      expect(loads.totalTorque.length, lessThan(1e-9));
      expect(
        loads.centerOfBuoyancy!.distanceTo(const Vec3(0, 0, -.5)),
        lessThan(1e-12),
      );
      final heavy = forceBody(
        frame,
        mass: 10000,
        position: const Vec3(0, 0, -2),
      );
      final sinking = solver.solve(
        heavy,
        shape,
        planeSamples(solver, heavy, shape),
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect((sinking.totalForce + gravity * heavy.mass).z, lessThan(0));
      final dry = forceBody(frame, position: const Vec3(0, 0, 2));
      final empty = solver.solve(
        dry,
        shape,
        planeSamples(solver, dry, shape),
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(empty.displacedVolume, 0);
      expect(empty.centerOfBuoyancy, isNull);
      expect(empty.totalForce, Vec3.zero);
      final zero = solver.solve(
        body,
        shape,
        planeSamples(solver, body, shape),
        gravity: Vec3.zero,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(zero.totalForce, Vec3.zero);
    },
  );
  test(
    'tilted distributed pontoons create a righting torque opposite heel',
    () {
      final frame = forceFrame(), solver = BuoyancySolver();
      final shape = BuoyancyProbes([
        BuoyancyProbe(const Vec3(-2, 0, 0), .5),
        BuoyancyProbe(const Vec3(2, 0, 0), .5),
      ]);
      for (final angle in [-.1, .1]) {
        final body = forceBody(
          frame,
          rotation: Quat.axisAngle(const Vec3(0, 1, 0), angle),
        );
        final loads = solver.solve(
          body,
          shape,
          planeSamples(solver, body, shape),
          gravity: gravity,
          density: 1000,
          stepSeconds: 1 / 60,
        );
        expect(loads.totalTorque.y * angle, lessThan(0));
        expect(loads.totalForce.x, 0);
        expect(loads.totalForce.y, 0);
      }
      final body = forceBody(frame), normal = const Vec3(.3, 0, 1).normalized();
      final loads = solver.solve(
        body,
        shape,
        planeSamples(solver, body, shape, normal: normal),
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(loads.totalForce.x, 0);
      expect(loads.totalForce.z, greaterThan(0));
    },
  );
  test('query identities, order, frame and body pose fence every sample', () {
    final frame = forceFrame(),
        solver = BuoyancySolver(),
        shape = boxHull(),
        body = forceBody(frame);
    final samples = planeSamples(solver, body, shape);
    void solve(BuoyancyBodyState b, List<OceanSample> s) => solver.solve(
      b,
      shape,
      s,
      gravity: gravity,
      density: 1000,
      stepSeconds: 1 / 60,
    );
    expect(() => solve(body, samples.reversed.toList()), throwsArgumentError);
    expect(() => solve(body, samples.sublist(1)), throwsArgumentError);
    expect(() => solve(forceBody(frame), samples), throwsArgumentError);
    frame.rebase(Geodetic(.1, .1));
    expect(() => solve(body, samples), throwsStateError);
  });
  test(
    'failed, stale, mixed-source and excessive-error samples yield no loads',
    () {
      final frame = forceFrame(),
          solver = BuoyancySolver(),
          body = forceBody(frame),
          shape = boxHull();
      final samples = planeSamples(solver, body, shape);
      OceanSample replace({
        OceanQueryFailure? failure,
        String source = 'sea',
        GeoInstant? evaluated,
        Duration age = Duration.zero,
        OceanQuery? query,
        OceanSurfaceAccuracy? accuracy,
      }) {
        final s = samples.first;
        return OceanSample(
          query: query ?? s.query,
          failure: failure,
          value: failure == null ? s.value : null,
          accuracy: failure == null ? (accuracy ?? s.accuracy) : null,
          seaStateRevision: source,
          coverageRevision: s.coverageRevision,
          frameId: s.frameId,
          frameRevision: s.frameRevision,
          evaluatedTime: evaluated ?? s.evaluatedTime,
          age: age,
          residual: 0,
        );
      }

      for (final invalid in [
        replace(failure: OceanQueryFailure.closed),
        replace(source: 'changed'),
        replace(evaluated: body.time.withTick(body.time.tick - 1)),
        replace(age: const Duration(microseconds: 1)),
        replace(query: OceanQuery(samples.first.query.positionEcef, body.time)),
        replace(accuracy: const OceanSurfaceAccuracy(.02, 0, 0, 0)),
        replace(accuracy: const OceanSurfaceAccuracy(0, double.nan, 0, 0)),
      ]) {
        expect(
          () => solver.solve(
            body,
            shape,
            [invalid, ...samples.skip(1)],
            gravity: gravity,
            density: 1000,
            stepSeconds: 1 / 60,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'canonical CPU samples feed buoyancy without repacking query identity',
    () async {
      final frame = forceFrame(),
          solver = BuoyancySolver(),
          body = forceBody(frame),
          shape = boxHull();
      final state = OceanSeaState(
        seed: 7,
        canonicalResolution: 8,
        bands: [
          OceanWaveBand(
            patchMetres: 64,
            minWaveNumber: 0,
            maxWaveNumber: .5,
            windSpeed: 12,
            windHeadingRadians: 0,
            amplitude: 0,
            choppiness: 0,
          ),
        ],
      );
      final sampler = await OceanSamplerCpu.create(
        state: state,
        frame: frame,
        now: () => forceTime,
        coverage: const OceanAllWaterCoverage(),
      );
      try {
        final samples = await sampler.sampleBatch(
          solver.queries(body, shape),
          OceanQueryPolicy(),
        );
        expect(samples.every((s) => s.available), isTrue);
        final loads = solver.solve(
          body,
          shape,
          samples,
          gravity: gravity,
          density: 1000,
          stepSeconds: 1 / 60,
        );
        expect(loads.displacedVolume, closeTo(4, 1e-5));
        expect(loads.diagnostics.maxHeightErrorMetres, lessThan(.01));
      } finally {
        await sampler.close();
      }
    },
  );
  test(
    'plane uncertainty produces a volume interval, not a curvature claim',
    () {
      final frame = forceFrame(),
          solver = BuoyancySolver(),
          body = forceBody(frame),
          shape = boxHull();
      final loads = solver.solve(
        body,
        shape,
        planeSamples(solver, body, shape, error: .01),
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(loads.diagnostics.minimumVolume, closeTo(3.96, 1e-10));
      expect(loads.diagnostics.maximumVolume, closeTo(4.04, 1e-10));
      expect(loads.diagnostics.surfaceCurvatureErrorMetres, isNull);
    },
  );
  test(
    'coupled drag dissipates energy without reversing any point projection',
    () {
      final frame = forceFrame(), shape = boxHull();
      final solver = BuoyancySolver(
        drag: BuoyancyDrag(linear: 1e7, quadratic: 1e7, angular: 1e7),
      );
      final body = forceBody(
        frame,
        position: const Vec3(0, 0, -2),
        velocity: const Vec3(3, -1, 2),
        angularVelocity: const Vec3(1, 2, -1),
        mass: 10,
      );
      for (final dt in [1 / 30, 1 / 60, 1 / 120]) {
        final loads = solver.solve(
          body,
          shape,
          planeSamples(solver, body, shape),
          gravity: Vec3.zero,
          density: 1000,
          stepSeconds: dt,
        );
        final dv = loads.totalForce * (dt / body.mass),
            dw = body.inverseInertia.apply(loads.totalTorque) * dt;
        final energy0 =
            .5 *
            body.mass *
            (body.linearVelocity.length2 + body.angularVelocity.length2);
        final energy1 =
            .5 *
            body.mass *
            ((body.linearVelocity + dv).length2 +
                (body.angularVelocity + dw).length2);
        expect(energy1, lessThan(energy0));
        for (final load in loads.points) {
          final r = load.position - body.centerOfMass;
          final before = body.linearVelocity + body.angularVelocity.cross(r);
          final after = before + dv + dw.cross(r);
          expect(after.dot(before), greaterThanOrEqualTo(-1e-8));
        }
        expect(loads.diagnostics.dragScale, lessThan(1));
      }
      final rest = forceBody(frame, position: const Vec3(0, 0, -2), mass: 10);
      final current = solver.solve(
        rest,
        shape,
        planeSamples(solver, rest, shape, waterVelocity: const Vec3(2, 0, 0)),
        gravity: Vec3.zero,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      expect(current.totalForce.x, greaterThan(0));
      expect(current.totalForce.x / 10 / 60, lessThanOrEqualTo(2 + 1e-12));
    },
  );
  test('refinement converges for a curved water height', () {
    final frame = forceFrame(),
        solver = BuoyancySolver(),
        body = forceBody(frame);
    final errors = <double>[];
    for (final depth in [0, 3, 6, 8]) {
      final shape = boxHull(subdivisions: depth);
      final values = planeSamples(
        solver,
        body,
        shape,
        height: (p) => .2 * p.x * p.x,
      );
      // Integral over [-1,1]^2 of (1 + .2*x^2).
      final loads = solver.solve(
        body,
        shape,
        values,
        gravity: gravity,
        density: 1000,
        stepSeconds: 1 / 60,
      );
      errors.add((loads.displacedVolume - (4 + .8 / 3)).abs());
    }
    expect(errors.last, lessThan(errors.first / 3));
    expect(errors.last, lessThan(.02));
  });
  test('invalid mass, inertia, time step and force inputs are rejected', () {
    final frame = forceFrame(),
        solver = BuoyancySolver(),
        body = forceBody(frame),
        shape = boxHull();
    expect(() => forceBody(frame, mass: 0), throwsArgumentError);
    expect(() => BuoyancyInverseInertia(1, 1, -1), throwsArgumentError);
    expect(() => BuoyancyInverseInertia(1, 1, 1, xy: 2), throwsArgumentError);
    expect(() => BuoyancyInverseInertia(double.nan, 1, 1), throwsArgumentError);
    final samples = planeSamples(solver, body, shape);
    for (final dt in [0.0, -1.0, double.infinity]) {
      expect(
        () => solver.solve(
          body,
          shape,
          samples,
          gravity: gravity,
          density: 1000,
          stepSeconds: dt,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => solver.solve(
        body,
        shape,
        samples,
        gravity: gravity,
        density: double.nan,
        stepSeconds: 1 / 60,
      ),
      throwsArgumentError,
    );
    expect(() => BuoyancyDrag(linear: -1), throwsArgumentError);
    expect(submergedSphereVolume(1, 1), closeTo(2 * math.pi / 3, 1e-12));
  });
}
