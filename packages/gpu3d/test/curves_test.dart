import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'procedural_geometry_test.dart' show checkSurface;

void main() {
  test('Catmull-Rom interior samples match the pinned Three.js reference', () {
    final data =
        jsonDecode(File('test/fixtures/catmull_rom.json').readAsStringSync())
            as Map;
    Vec3 vector(Object? value) =>
        Vec3.array((value as List).map((v) => (v as num).toDouble()).toList());
    final controls = (data['controls'] as List).map(vector).toList();
    for (final c in data['cases'] as List) {
      final curve = CatmullRomCurve3(
        controls,
        closed: c['closed'] as bool,
        tension: .3,
        type: switch (c['type']) {
          'chordal' => CatmullRomType.chordal,
          'catmullrom' => CatmullRomType.uniform,
          _ => CatmullRomType.centripetal,
        },
      );
      for (final sample in c['samples'] as List) {
        expect(
          curve
              .pointAt((sample['t'] as num).toDouble())
              .distanceTo(vector(sample['point'])),
          lessThan(1e-12),
        );
      }
    }
  });
  test('Bezier samples and tangents match analytic reference values', () {
    final line = LineCurve3(Vec3.zero, const Vec3(4, 0, 0));
    expect(line.pointAt(.25), const Vec3(1, 0, 0));
    expect(line.sample().length, 4);
    final quadratic = QuadraticBezierCurve3(
      Vec3.zero,
      const Vec3(1, 2, 0),
      const Vec3(2, 0, 0),
    );
    expect(quadratic.pointAt(.5), const Vec3(1, 1, 0));
    expect(quadratic.tangentAt(.5), const Vec3(1, 0, 0));
    final cubic = CubicBezierCurve3(
      Vec3.zero,
      const Vec3(0, 2, 0),
      const Vec3(2, 2, 0),
      const Vec3(2, 0, 0),
    );
    expect(cubic.pointAt(.5), const Vec3(1, 1.5, 0));
    expect(cubic.tangentAt(0), const Vec3(0, 1, 0));
    expect(cubic.tangentAt(1), const Vec3(0, -1, 0));
    expect(cubic.sample(divisions: 2000).length, closeTo(4, 1e-5));
    final samples = cubic.spacedPoints(segments: 20, divisions: 2000);
    final distances = [
      for (var i = 1; i < samples.length; i++)
        samples[i].distanceTo(samples[i - 1]),
    ];
    expect(distances.every((d) => d > .197 && d < .201), isTrue);
  });
  test(
    'Catmull-Rom interpolates controls with stable repeated points and closure',
    () {
      final controls = [
        Vec3.zero,
        const Vec3(1, 2, 0),
        const Vec3(3, 1, 0),
        const Vec3(4, 0, 0),
      ];
      for (final type in CatmullRomType.values) {
        final curve = CatmullRomCurve3(controls, type: type);
        for (var i = 0; i < controls.length; i++) {
          expect(curve.pointAt(i / 3).distanceTo(controls[i]), lessThan(1e-12));
        }
        final repeated = CatmullRomCurve3([
          controls[0],
          controls[0],
          controls[1],
          controls[1],
        ], type: type);
        expect(repeated.points(segments: 100).every((p) => p.isFinite), isTrue);
      }
      final closed = CatmullRomCurve3(controls, closed: true);
      expect(closed.pointAt(0), closed.pointAt(1));
      controls[0] = const Vec3(99, 99, 99);
      expect(closed.pointAt(0), Vec3.zero);
    },
  );
  test('tube has analytic straight bounds and closes its frame seam', () {
    final line = LineCurve3(const Vec3(0, -1, 0), const Vec3(0, 1, 0));
    final tube = TubeGeometry(
      line,
      radius: .5,
      tubularSegments: 8,
      radialSegments: 8,
    );
    checkSurface(tube);
    expect(tube.capture().bounds.minimum, const Vec3(-.5, -1, -.5));
    expect(tube.capture().bounds.maximum, const Vec3(.5, 1, .5));
    final loop = CatmullRomCurve3([
      const Vec3(2, 0, 0),
      const Vec3(0, 2, 1),
      const Vec3(-2, 0, 0),
      const Vec3(0, -2, -1),
    ], closed: true);
    final ring = TubeGeometry(
      loop,
      radius: .1,
      closed: true,
      tubularSegments: 64,
      radialSegments: 8,
    );
    checkSurface(ring);
    for (var i = 0; i <= 8; i++) {
      expect(
        Vec3.array(
          ring.positions,
          i * 3,
        ).distanceTo(Vec3.array(ring.positions, (64 * 9 + i) * 3)),
        lessThan(1e-6),
      );
      expect(
        Vec3.array(
          ring.normals,
          i * 3,
        ).distanceTo(Vec3.array(ring.normals, (64 * 9 + i) * 3)),
        lessThan(1e-6),
      );
    }
  });
  test(
    'sampling and tubes reject invalid inputs without allocating unbounded data',
    () {
      final line = LineCurve3(Vec3.zero, Vec3.one);
      expect(() => line.pointAt(-.01), throwsArgumentError);
      expect(() => line.pointAt(double.nan), throwsArgumentError);
      expect(() => line.sample(divisions: 1000001), throwsArgumentError);
      expect(() => TubeGeometry(line, closed: true), throwsArgumentError);
      expect(
        () => TubeGeometry(LineCurve3(Vec3.zero, Vec3.zero)),
        throwsArgumentError,
      );
      expect(
        () => TubeGeometry(line, tubularSegments: 1000000),
        throwsArgumentError,
      );
    },
  );
}
