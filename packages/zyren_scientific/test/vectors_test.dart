import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'scientific_test.dart' show grid, transfer;

VectorGrid3D vectorField(
  Vec3? Function(Vec3) sample, {
  int n = 21,
  VectorBasis? basis,
}) {
  final values = [
    for (var z = 0; z < 2; z++)
      for (var y = 0; y < n; y++)
        for (var x = 0; x < n; x++) sample(Vec3(x * .1, y * .1, z * .1)),
  ];
  ScalarGrid3D component(int axis) => grid(
    x: n,
    y: n,
    z: 2,
    spacing: const Vec3(.1, .1, .1),
    values: [for (final v in values) v?.storage[axis]],
  );
  return VectorGrid3D(
    x: component(0),
    y: component(1),
    z: component(2),
    basis: basis ?? VectorBasis.cartesian(),
  );
}

void main() {
  test(
    'trilinear sampling ignores unused missing corners and transforms basis',
    () {
      final f = vectorField(
        (p) => p.x == 0 ? const Vec3(1, 0, 0) : null,
        basis: VectorBasis(
          x: const Vec3(0, 1, 0),
          y: const Vec3(-1, 0, 0),
          z: const Vec3(0, 0, 1),
        ),
      );
      expect(f.sample(const Vec3(0, .5, 0)).value, const Vec3(0, 1, 0));
      expect(
        f.sample(const Vec3(.05, .5, 0)).status,
        ScientificSampleStatus.missing,
      );
      expect(
        f.sample(const Vec3(-1, .5, 0)).status,
        ScientificSampleStatus.outside,
      );
      expect(
        () => VectorBasis(x: Vec3.one, y: Vec3.one, z: Vec3.one),
        throwsArgumentError,
      );
    },
  );
  test('constant and divergent field lines match exact paths', () async {
    final f = vectorField((p) => const Vec3(2, 0, 0));
    final s = await integrateStreamline(
      field: f,
      seed: const Vec3(.1, .5, 0),
      options: StreamlineOptions(maxLength: .7),
    );
    expect(s.termination, StreamlineTermination.length);
    expect(s.points.last.distanceTo(const Vec3(.8, .5, 0)), lessThan(1e-12));
    final boundary = await integrateStreamline(
      field: f,
      seed: const Vec3(1.9, .5, 0),
    );
    expect(boundary.termination, StreamlineTermination.domain);
    expect(boundary.points.last.x, closeTo(2, 2e-5));
    final divergent = await integrateStreamline(
      field: vectorField((p) => p - const Vec3(1, 1, 0)),
      seed: const Vec3(1.1, 1.1, 0),
      options: StreamlineOptions(maxLength: .5),
    );
    final expected = 1.1 + .5 / math.sqrt(2);
    expect(
      divergent.points.last.distanceTo(Vec3(expected, expected, 0)),
      lessThan(1e-12),
    );
  });
  test(
    'rotational RK4 error and deterministic cancellation and termination',
    () async {
      final f = vectorField((p) => Vec3(-(p.y - 1), p.x - 1, 0));
      final o = StreamlineOptions(
        maxLength: math.pi,
        tolerance: 1e-8,
        minStep: 1e-6,
      );
      final s = await integrateStreamline(
        field: f,
        seed: const Vec3(1.5, 1, 0),
        options: o,
      );
      final error = s.points.last.distanceTo(const Vec3(1.5, 1, 0));
      expect(s.termination, StreamlineTermination.length);
      expect(error, lessThan(2e-7));
      expect(s.maxLocalError, lessThanOrEqualTo(1e-8));
      final second = await integrateStreamline(
        field: f,
        seed: const Vec3(1.5, 1, 0),
        options: o,
      );
      expect(second.points, s.points);
      final stagnation = await integrateStreamline(
        field: f,
        seed: const Vec3(1, 1, 0),
      );
      expect(stagnation.termination, StreamlineTermination.stagnation);
      final limited = await integrateStreamline(
        field: f,
        seed: const Vec3(1.5, 1, 0),
        options: StreamlineOptions(maxSteps: 1),
      );
      expect(limited.termination, StreamlineTermination.workLimit);
      final token = ScientificCancellation();
      final future = integrateStreamline(
        field: f,
        seed: const Vec3(1.5, 1, 0),
        cancellation: token,
      );
      token.cancel();
      await expectLater(future, throwsA(isA<ScientificCancelled>()));
      print(
        'STREAMLINE circle endpointError=$error m localError=${s.maxLocalError} m attempts=${s.attempts}',
      );
    },
  );
  test(
    'missing data terminates and geometry budgets never silently thin glyphs',
    () async {
      final f = vectorField((p) => p.x >= 1 ? null : const Vec3(1, 0, 0));
      final s = await integrateStreamline(
        field: f,
        seed: const Vec3(.1, .5, 0),
      );
      expect(s.termination, StreamlineTermination.missing);
      final g = await buildVectorGlyphs(
        field: f,
        transfer: transfer(),
        lengthScale: .03,
        coordinateTolerance: 1e-6,
        stride: 5,
      );
      expect(g.geometry, isNotNull);
      expect(g.sourceSamples.length, g.geometry!.indices.length ~/ 2);
      await expectLater(
        buildVectorGlyphs(
          field: f,
          transfer: transfer(),
          lengthScale: .03,
          coordinateTolerance: 1e-6,
          maxGlyphs: 1,
        ),
        throwsArgumentError,
      );
      final lines = s.geometry(transfer: transfer(), coordinateTolerance: 1e-6);
      expect(lines.geometry!.indices.length, (s.points.length - 1) * 2);
    },
  );
}
