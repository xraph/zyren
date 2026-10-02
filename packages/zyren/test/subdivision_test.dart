import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

BufferGeometry mesh(List<double> p, List<int> indices) => BufferGeometry(
  positions: p,
  normals: [
    for (var i = 0; i < p.length; i += 3) ...[0, 0, 1],
  ],
  indices: indices,
);

List<Vec3> points(BufferGeometry g) => [
  for (var i = 0; i < g.positions.length; i += 3) Vec3.array(g.positions, i),
];

void main() {
  test('high valence interior uses the whole fan', () {
    final source = mesh(
      [
        0,
        0,
        1,
        for (var i = 0; i < 8; i++) ...[
          math.cos(i * math.pi / 4),
          math.sin(i * math.pi / 4),
          0,
        ],
      ],
      [
        for (var i = 0; i < 8; i++) ...[0, i + 1, (i + 1) % 8 + 1],
      ],
    );
    final result = GeometryUtils.subdivide(source);
    final center = points(result).first;
    expect(center.x, closeTo(0, 1e-8));
    expect(center.y, closeTo(0, 1e-8));
    expect(center.z, .625);
  });

  test('rejects disconnected closed vertex fans and float32 collapse', () {
    final touching = mesh(
      [1, 1, 1, -1, -1, 1, -1, 1, -1, 1, -1, -1, 3, 3, 1, 3, 1, 3, 1, 3, 3],
      [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3, 0, 4, 5, 0, 6, 4, 0, 5, 6, 4, 6, 5],
    );
    expect(() => GeometryUtils.subdivide(touching), throwsArgumentError);
    final small = mesh(
      [16777216, 0, 0, 16777218, 0, 0, 16777216, 2, 0],
      [0, 1, 2],
    );
    expect(
      () => GeometryUtils.subdivide(small, mode: SubdivisionMode.linear),
      throwsArgumentError,
    );
  });

  test(
    'linear normals preserve authored creases and reject cancelling interpolation',
    () {
      final box = BoxGeometry();
      final result = GeometryUtils.subdivide(box, mode: SubdivisionMode.linear);
      for (var f = 0; f < box.indices.length ~/ 3; f++) {
        final n = Vec3.array(box.normals, box.indices[f * 3] * 3);
        for (var c = 0; c < 12; c++) {
          expect(Vec3.array(result.normals, (f * 12 + c) * 3), n);
        }
      }
      final opposed = BufferGeometry(
        positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        normals: [0, 0, 1, 0, 0, -1, 0, 0, 1],
        indices: [0, 1, 2],
      );
      expect(
        () => GeometryUtils.subdivide(opposed, mode: SubdivisionMode.linear),
        throwsArgumentError,
      );
    },
  );

  test('Loop boundary and odd vertices match a hand-calculated triangle', () {
    final source = mesh([0, 0, 0, 2, 0, 0, 0, 2, 0], [0, 1, 2]);
    final result = GeometryUtils.subdivide(source);
    expect(result.indices.length, 12);
    expect(points(result).toSet(), {
      const Vec3(.25, .25, 0),
      const Vec3(1.5, .25, 0),
      const Vec3(.25, 1.5, 0),
      const Vec3(1, 0, 0),
      const Vec3(1, 1, 0),
      const Vec3(0, 1, 0),
    });
    expect(result.normals, [
      for (var i = 0; i < 12; i++) ...[0, 0, 1],
    ]);
    expect(source.positions, [0, 0, 0, 2, 0, 0, 0, 2, 0]);
    expect(result.id, isNot(source.id));
  });

  test(
    'Loop closed tetrahedron uses both opposite vertices and valence weights',
    () {
      final tetra = mesh(
        [1, 1, 1, -1, -1, 1, -1, 1, -1, 1, -1, -1],
        [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3],
      );
      final result = GeometryUtils.subdivide(tetra);
      expect(points(result).toSet(), {
        const Vec3(.25, .25, .25),
        const Vec3(-.25, -.25, .25),
        const Vec3(-.25, .25, -.25),
        const Vec3(.25, -.25, -.25),
        const Vec3(.5, 0, 0),
        const Vec3(-.5, 0, 0),
        const Vec3(0, .5, 0),
        const Vec3(0, -.5, 0),
        const Vec3(0, 0, .5),
        const Vec3(0, 0, -.5),
      });
      for (var i = 0; i < result.vertexCount; i++) {
        expect(
          Vec3.array(
            result.positions,
            i * 3,
          ).dot(Vec3.array(result.normals, i * 3)),
          greaterThan(0),
        );
      }
      expect(GeometryUtils.subdivide(tetra, levels: 3).indices.length, 12 * 64);
    },
  );

  test('position welding closes face seams while keeping independent UVs', () {
    final source = BoxGeometry();
    final result = GeometryUtils.subdivide(source, levels: 2);
    final seams = <Vec3, Set<(double, double)>>{};
    final normals = <Vec3, Vec3>{};
    for (var i = 0; i < result.vertexCount; i++) {
      final p = Vec3.array(result.positions, i * 3);
      seams.putIfAbsent(p, () => {}).add((
        result.uv0![i * 2],
        result.uv0![i * 2 + 1],
      ));
      final n = Vec3.array(result.normals, i * 3);
      if (normals.containsKey(p)) expect(n, normals[p]);
      normals[p] = n;
    }
    expect(seams.values.any((v) => v.length > 1), isTrue);
    final edges = <(Vec3, Vec3), int>{};
    final ids = {for (final p in points(result)) p: 0};
    var next = 0;
    for (final p in ids.keys) {
      ids[p] = next++;
    }
    for (var f = 0; f < result.indices.length; f += 3) {
      for (var c = 0; c < 3; c++) {
        final a = points(result)[f + c], b = points(result)[f + (c + 1) % 3];
        final key = ids[a]! < ids[b]! ? (a, b) : (b, a);
        edges.update(key, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    expect(edges.values.every((count) => count == 2), isTrue);
    expect(
      points(GeometryUtils.subdivide(source, weldPositions: false)).toSet(),
      isNot(points(GeometryUtils.subdivide(source)).toSet()),
    );
  });

  test(
    'linear mode keeps the surface and interpolates both UVs and packed color',
    () {
      final triangle = mesh([0, 0, 0, 2, 0, 0, 0, 2, 0], [0, 1, 2]);
      final source = BufferGeometry.fromAttributes(
        attributes: {
          ...triangle.attributes,
          VertexSemantic.uv0: VertexAttribute(
            Float32List.fromList([0, 0, 1, 0, 0, 1]),
            format: VertexFormat.float32x2,
          ),
          VertexSemantic.uv1: VertexAttribute(
            Float32List.fromList([2, 2, 4, 2, 2, 4]),
            format: VertexFormat.float32x2,
          ),
          VertexSemantic.color: VertexAttribute(
            Uint8List.fromList([
              255,
              0,
              0,
              255,
              0,
              255,
              0,
              255,
              0,
              0,
              255,
              255,
            ]),
            format: VertexFormat.unorm8x4,
          ),
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 3; i++) ...[1, 0, 0, 1],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: triangle.indices,
      );
      final result = GeometryUtils.subdivide(
        source,
        mode: SubdivisionMode.linear,
      );
      final i = points(result).indexOf(const Vec3(1, 0, 0));
      expect(i, greaterThanOrEqualTo(0));
      expect(result.uv0!.sublist(i * 2, i * 2 + 2), [.5, 0]);
      expect(result.uv1!.sublist(i * 2, i * 2 + 2), [3, 2]);
      expect(
        (result.attributes[VertexSemantic.color]!.data as Uint8List).sublist(
          i * 4,
          i * 4 + 4,
        ),
        [128, 128, 0, 255],
      );
      expect(result.attributes.containsKey(VertexSemantic.tangent), isFalse);
      expect(points(result).toSet().containsAll(points(source)), isTrue);
    },
  );

  test(
    'worker output can create a geometry without allocating IDs in the worker',
    () async {
      final source = PlaneGeometry();
      final data = GeometryData(
        attributes: source.attributes,
        indices: source.indices,
      );
      final result = await Isolate.run(
        () => subdivideGeometry(data, levels: 2),
      );
      expect(result.indices.length, 96);
      expect(BufferGeometry.fromData(result).vertexCount, 96);
    },
  );

  test(
    'limits and unsupported deformation fail without mutating the source',
    () {
      final source = BoxGeometry();
      expect(
        () => GeometryUtils.subdivide(source, levels: -1),
        throwsArgumentError,
      );
      expect(
        () => GeometryUtils.subdivide(source, levels: 7),
        throwsArgumentError,
      );
      expect(
        () => GeometryUtils.subdivide(
          source,
          limits: const SubdivisionLimits(maxTriangles: 47),
        ),
        throwsArgumentError,
      );
      expect(
        () => GeometryUtils.subdivide(
          source,
          limits: const SubdivisionLimits(maxBytes: 100),
        ),
        throwsArgumentError,
      );
      expect(
        () => GeometryUtils.subdivide(
          source,
          levels: 6,
          indexFormat: IndexFormat.uint16,
        ),
        throwsArgumentError,
      );
      expect(
        () => GeometryUtils.subdivide(
          source,
          limits: const SubdivisionLimits(maxTriangles: 250001),
        ),
        throwsArgumentError,
      );
      final morph = BufferGeometry.fromAttributes(
        attributes: source.attributes,
        indices: source.indices,
        morphTargets: [
          MorphTarget(
            name: 'up',
            positions: List.filled(source.vertexCount * 3, 0),
          ),
        ],
      );
      expect(() => GeometryUtils.subdivide(morph), throwsArgumentError);
      expect(source.vertexCount, 24);
      expect(source.revision, 0);
    },
  );

  test(
    'rejects degenerate faces, reversed neighbors, duplicate faces and bow ties',
    () {
      for (final source in [
        mesh([0, 0, 0, 1, 0, 0, 2, 0, 0], [0, 1, 2]),
        mesh([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -1, 0], [0, 1, 2, 0, 1, 3]),
        mesh([0, 0, 0, 1, 0, 0, 0, 1, 0], [0, 1, 2, 0, 2, 1]),
        mesh(
          [0, 0, 0, 1, 0, 0, 0, 1, 0, -1, 0, 0, 0, -1, 0],
          [0, 1, 2, 0, 3, 4],
        ),
        mesh(
          [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1],
          [0, 1, 2, 1, 0, 3, 0, 1, 4],
        ),
      ]) {
        expect(() => GeometryUtils.subdivide(source), throwsArgumentError);
      }
    },
  );
}
