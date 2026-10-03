import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'cube_patch.dart';
import 'coverage.dart';

final class OceanEdge {
  final OceanPatchId patch;
  final OceanPatchSide side;
  final Ellipsoid ellipsoid;
  final double start, end;
  const OceanEdge(
    this.patch,
    this.side,
    this.ellipsoid, {
    this.start = 0,
    this.end = 1,
  });
  Vec3 point(double t) {
    if (!t.isFinite || t < 0 || t > 1) {
      throw ArgumentError('Invalid edge fraction.');
    }
    final uv = oceanEdgeUv(side, start + (end - start) * t);
    return patch.point(uv.u.clamp(0, 1), uv.v.clamp(0, 1), ellipsoid);
  }
}

final class OceanSharedEdge {
  final OceanEdge first, second;
  const OceanSharedEdge(this.first, this.second);
}

final class OceanPatchNeighbours {
  final Set<OceanPatchId> patches;
  final Ellipsoid ellipsoid;
  late final int maximumLevel = patches.map((p) => p.level).reduce(math.max);
  OceanPatchNeighbours(
    Iterable<OceanPatchId> patches, {
    this.ellipsoid = Ellipsoid.wgs84,
  }) : patches = Set.unmodifiable(OceanPatchCoverage(patches).patches);
  OceanPatchId containing(Vec3 cube) {
    final face = oceanCubeFace(cube),
        root = OceanPatchId(face: face, level: 0, x: 0, y: 0);
    final uv = root.localCoordinates(cube);
    for (var level = 0; level <= maximumLevel; level++) {
      final n = 1 << level;
      final p = OceanPatchId(
        face: face,
        level: level,
        x: (uv.u * n).floor().clamp(0, n - 1),
        y: (uv.v * n).floor().clamp(0, n - 1),
      );
      if (patches.contains(p)) return p;
    }
    throw StateError('Cube coverage is incomplete.');
  }

  OceanPatchId across(
    OceanPatchId patch,
    OceanPatchSide side, [
    double t = .5,
  ]) {
    final uv = oceanEdgeUv(side, t);
    const e = 1e-6;
    final du = side == OceanPatchSide.west
        ? -e
        : side == OceanPatchSide.east
        ? e
        : 0.0;
    final dv = side == OceanPatchSide.south
        ? -e
        : side == OceanPatchSide.north
        ? e
        : 0.0;
    return containing(patch.cubePoint(uv.u + du, uv.v + dv));
  }

  Set<OceanPatchId> adjacent(OceanPatchId patch, OceanPatchSide side) => {
    across(patch, side, .25),
    across(patch, side, .75),
  };
  List<OceanSharedEdge> get sharedEdges {
    final result = <OceanSharedEdge>[];
    for (final patch in patches) {
      for (final side in OceanPatchSide.values) {
        final other = across(patch, side);
        if (patch.level < other.level ||
            (patch.level == other.level &&
                patch.toString().compareTo(other.toString()) > 0)) {
          continue;
        }
        if ((patch.level - other.level).abs() > 1) {
          throw StateError('Ocean neighbours differ by more than one level.');
        }
        final start = oceanEdgeUv(side, 0),
            end = oceanEdgeUv(side, 1),
            middle = oceanEdgeUv(side, .5);
        final a = other.localCoordinates(patch.cubePoint(start.u, start.v));
        final b = other.localCoordinates(patch.cubePoint(end.u, end.v));
        final m = other.localCoordinates(patch.cubePoint(middle.u, middle.v));
        final distances = [
          m.v.abs(),
          (1 - m.u).abs(),
          (1 - m.v).abs(),
          m.u.abs(),
        ];
        final otherSide = OceanPatchSide
            .values[distances.indexOf(distances.reduce(math.min))];
        double fraction(({double u, double v}) uv) => switch (otherSide) {
          OceanPatchSide.south => uv.u,
          OceanPatchSide.east => uv.v,
          OceanPatchSide.north => 1 - uv.u,
          OceanPatchSide.west => 1 - uv.v,
        };
        result.add(
          OceanSharedEdge(
            OceanEdge(patch, side, ellipsoid),
            OceanEdge(
              other,
              otherSide,
              ellipsoid,
              start: fraction(b).clamp(0, 1),
              end: fraction(a).clamp(0, 1),
            ),
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }
}
