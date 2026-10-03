import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'scientific_test.dart' show grid, transfer, source, metres;

void main() {
  test(
    'affine isosurface has shared vertices, stable cells and increasing normals',
    () async {
      final field = grid(x: 5, y: 5, z: 5);
      final surface = await extractIsosurface(
        grid: field,
        threshold: 23.5,
        transfer: transfer(),
        coordinateTolerance: 1e-6,
      );
      final data = surface.geometry!;
      final positions =
          data.attributes[VertexSemantic.position]!.data as Float32List;
      final normals =
          data.attributes[VertexSemantic.normal]!.data as Float32List;
      final unique = <Vec3>{};
      for (var i = 0; i < positions.length; i += 3) {
        final p = Vec3.array(positions, i), n = Vec3.array(normals, i);
        expect(10 + 2 * p.x + 3 * p.y + 5 * p.z, closeTo(23.5, 2e-6));
        expect(n.dot(const Vec3(2, 3, 5).normalized()), closeTo(1, 1e-6));
        expect(unique.add(p), isTrue);
      }
      expect(surface.sourceCells.length, data.indices.length ~/ 3);
      expect(surface.sourceCells.every((i) => i >= 0 && i < 64), isTrue);
      final second = await extractIsosurface(
        grid: field,
        threshold: 23.5,
        transfer: transfer(),
        coordinateTolerance: 1e-6,
      );
      expect(second.geometry!.indices, data.indices);
      expect(second.sourceCells, surface.sourceCells);
    },
  );
  test(
    'sphere is closed, consistently wound and converges to analytic surface',
    () async {
      const n = 19;
      const step = .125;
      final field = grid(
        x: n,
        y: n,
        z: n,
        values: [
          for (var z = 0; z < n; z++)
            for (var y = 0; y < n; y++)
              for (var x = 0; x < n; x++)
                ((x - 9) * step) * ((x - 9) * step) +
                    ((y - 9) * step) * ((y - 9) * step) +
                    ((z - 9) * step) * ((z - 9) * step),
        ],
        spacing: const Vec3(step, step, step),
      );
      final s = await extractIsosurface(
        grid: field,
        threshold: .73 * .73,
        transfer: transfer(),
        coordinateTolerance: 1e-6,
      );
      final data = s.geometry!,
          p = data.attributes[VertexSemantic.position]!.data as Float32List;
      final edges = <(int, int), List<int>>{};
      var maxError = 0.0, maxNormalError = 0.0;
      final center = const Vec3(9 * step, 9 * step, 9 * step);
      for (var i = 0; i < data.indices.length; i += 3) {
        final a = data.indices[i],
            b = data.indices[i + 1],
            c = data.indices[i + 2];
        final pa = Vec3.array(p, a * 3),
            pb = Vec3.array(p, b * 3),
            pc = Vec3.array(p, c * 3);
        final n = (pb - pa).cross(pc - pa).normalized();
        final radial = ((pa + pb + pc) / 3 - center).normalized();
        expect(n.dot(radial), greaterThan(.97));
        maxNormalError = math.max(
          maxNormalError,
          math.acos(n.dot(radial).clamp(-1, 1)),
        );
        for (final e in [(a, b), (b, c), (c, a)]) {
          edges
              .putIfAbsent((
                math.min(e.$1, e.$2),
                math.max(e.$1, e.$2),
              ), () => [])
              .add(e.$1 < e.$2 ? 1 : -1);
        }
      }
      for (var i = 0; i < p.length; i += 3) {
        maxError = math.max(
          maxError,
          ((Vec3.array(p, i) - center).length - .73).abs(),
        );
      }
      expect(maxError, lessThan(.009));
      expect(
        edges.values.every((v) => v.length == 2 && v[0] + v[1] == 0),
        isTrue,
      );
      expect(p.length ~/ 3 - edges.length + data.indices.length ~/ 3, 2);
      print(
        'SPHERE radiusError=$maxError m faceNormalError=$maxNormalError rad closed oriented manifold',
      );
    },
  );
  test('equality, missing cells, cancellation and output ceilings', () async {
    final field = grid(x: 2, y: 2, z: 2, values: [0, 1, 0, 1, 0, 1, 0, 1]);
    final s = await extractIsosurface(
      grid: field,
      threshold: 0,
      transfer: transfer(),
      coordinateTolerance: 0,
    );
    expect(s.geometry!.indices.length, 6);
    final empty = await extractIsosurface(
      grid: grid(x: 2, y: 2, z: 2, values: [null, 1, 0, 1, 0, 1, 0, 1]),
      threshold: .5,
      transfer: transfer(),
      coordinateTolerance: 0,
    );
    expect(empty.geometry, isNull);
    expect(empty.omittedCells, 1);
    final token = ScientificCancellation();
    final work = extractIsosurface(
      grid: grid(x: 25, y: 25, z: 25),
      threshold: 80,
      transfer: transfer(),
      coordinateTolerance: 1e-5,
      cancellation: token,
    );
    token.cancel();
    await expectLater(work, throwsA(isA<ScientificCancelled>()));
    await expectLater(
      extractIsosurface(
        grid: field,
        threshold: .5,
        transfer: transfer(),
        coordinateTolerance: 0,
        budget: ScientificBudget(maxGeometryBytes: 100),
      ),
      throwsArgumentError,
    );
  });
  test(
    'unstructured vertex/cell association, validation and missing holes',
    () async {
      Future<ScientificSurface> build(
        List<int> indices,
        List<double?> values,
        ScalarAssociation association,
      ) => ScientificSurface.build(
        positions: const [
          Vec3(0, 0, 0),
          Vec3(1, 0, 0),
          Vec3(1, 1, 0),
          Vec3(0, 1, 0),
        ],
        indices: indices,
        values: values,
        association: association,
        origin: const Vec3(1e12, 0, 0),
        source: source,
        coordinateUnit: metres,
        transfer: transfer(),
        coordinateTolerance: 0,
      );
      final s = await build(
        [0, 1, 2, 0, 2, 3],
        [10, null],
        ScalarAssociation.cell,
      );
      expect(s.geometry!.indices.length, 3);
      expect(s.omittedCells, 1);
      expect(s.sourceCells, [0]);
      await expectLater(
        build([0, 1, 5], [1, 2, 3, 4], ScalarAssociation.vertex),
        throwsArgumentError,
      );
      await expectLater(
        build([0, 1, 1], [1, 2, 3, 4], ScalarAssociation.vertex),
        throwsArgumentError,
      );
    },
  );
}
