import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../surface/wave_chart.dart';
import '../surface/cube_patch.dart';
import '../surface/geometry.dart';
import '../surface/morph.dart';

final class _Control {
  final Vec3 position;
  final double weight, footprint;
  const _Control(this.position, this.weight, this.footprint);
}

/// Displace each parent control before interpolation. Displacing the interpolated
/// midpoint itself would reopen a crack next to an unsplit coarse edge.
final class OceanWaterPatchControls {
  final OceanPatchGeometry geometry;
  final Ellipsoid ellipsoid;
  late final Set<int> requiredChartIds = _requiredCharts();
  Set<int> _requiredCharts() {
    final charts = OceanWaveCharts(ellipsoid: ellipsoid, seed: 0);
    final points = {
      for (final v in _vertices)
        for (final c in [...v.$1, ...v.$2]) c.position,
    };
    return Set.unmodifiable({
      for (final point in points)
        for (final c in charts.atSurface(point).coordinates) c.id,
    });
  }

  final int segments;
  final bool morphing;
  final List<(List<_Control>, List<_Control>)> _vertices;
  int get vertexCount => _vertices.length;
  int get textureWidth => 256;
  int get textureHeight =>
      (vertexCount * 24 + textureWidth - 1) ~/ textureWidth;
  int get logicalBytes => textureWidth * textureHeight * 16;
  OceanWaterPatchControls._(
    this.geometry,
    this.ellipsoid,
    this.segments,
    this.morphing,
    this._vertices,
  );

  Float32List encode() {
    final out = Float32List(textureWidth * textureHeight * 4);
    for (var vertex = 0; vertex < vertexCount; vertex++) {
      final endpoints = [_vertices[vertex].$1, _vertices[vertex].$2];
      for (var end = 0; end < 2; end++) {
        for (var i = 0; i < endpoints[end].length; i++) {
          final control = endpoints[end][i],
              p = control.position - geometry.origin;
          final offset = vertex * 96 + end * 48 + i * 8;
          out.setRange(offset, offset + 8, [
            p.x,
            p.y,
            p.z,
            control.weight,
            control.footprint,
            0,
            0,
            0,
          ]);
        }
      }
    }
    return out;
  }

  Vec3 evaluateVertex(
    int vertex,
    double fraction,
    Vec3 Function(Vec3, double) displacement,
  ) {
    RangeError.checkValidIndex(vertex, _vertices);
    if (!fraction.isFinite || fraction < 0 || fraction > 1) {
      throw ArgumentError('Invalid water morph fraction.');
    }
    Vec3 endpoint(List<_Control> controls) => controls.fold(
      Vec3.zero,
      (sum, c) =>
          sum + (c.position + displacement(c.position, c.footprint)) * c.weight,
    );
    return endpoint(_vertices[vertex].$1) * (1 - fraction) +
        endpoint(_vertices[vertex].$2) * fraction;
  }

  /// CPU qualification of the actual triangle interpolation and control weights.
  Vec3 sample(
    double u,
    double v,
    double fraction,
    Vec3 Function(Vec3, double) displacement,
  ) => interpolateOceanGrid(
    segments,
    u,
    v,
    (i, j) => evaluateVertex(j * (segments + 1) + i, fraction, displacement),
  );
}

final class OceanWaterGeometry {
  final Map<OceanPatchId, OceanWaterPatchControls> _patches;
  OceanWaterGeometry._(this._patches);
  factory OceanWaterGeometry.fromSurface(OceanSurfaceGeometry surface) =>
      OceanWaterGeometry._build(surface, surface, surface.patches, false);
  factory OceanWaterGeometry.fromMorph(OceanSurfaceMorph morph) =>
      OceanWaterGeometry._build(morph.from, morph.to, morph.patches, true);
  factory OceanWaterGeometry._build(
    OceanSurfaceGeometry from,
    OceanSurfaceGeometry to,
    List<OceanPatchGeometry> patches,
    bool morphing,
  ) {
    final first = _Stencils(from),
        second = identical(from, to) ? null : _Stencils(to);
    return OceanWaterGeometry._({
      for (final patch in patches)
        patch.id: OceanWaterPatchControls._(
          patch,
          from.ellipsoid,
          from.segments,
          morphing,
          [
            for (var j = 0; j <= from.segments; j++)
              for (var i = 0; i <= from.segments; i++)
                (
                  first.cube(
                    patch.id.cubePoint(i / from.segments, j / from.segments),
                  ),
                  (second ?? first).cube(
                    patch.id.cubePoint(i / from.segments, j / from.segments),
                  ),
                ),
          ],
        ),
    });
  }
  List<OceanWaterPatchControls> get patches =>
      List.unmodifiable(_patches.values);
  OceanWaterPatchControls patch(OceanPatchId id) =>
      _patches[id] ?? (throw ArgumentError('Unknown water patch.'));
}

final class _Stencils {
  final OceanSurfaceGeometry surface;
  final _cache = <(OceanPatchId, int, int), List<_Control>>{};
  _Stencils(this.surface);
  List<_Control> cube(Vec3 point) {
    final p = surface.topology.containing(point),
        uv = p.localCoordinates(point);
    return at(p, uv.u.clamp(0, 1), uv.v.clamp(0, 1));
  }

  List<_Control> at(OceanPatchId p, double u, double v) {
    final n = surface.segments, x = u * n, y = v * n;
    final i = x.floor().clamp(0, n - 1), j = y.floor().clamp(0, n - 1);
    final tx = x - i, ty = y - j;
    final entries = tx >= ty
        ? [(i, j, 1 - tx), (i + 1, j, tx - ty), (i + 1, j + 1, ty)]
        : [(i, j, 1 - ty), (i + 1, j + 1, tx), (i, j + 1, ty - tx)];
    final result = <Vec3, _Control>{};
    for (final (x, y, weight) in entries) {
      if (weight == 0) continue;
      for (final c in vertex(p, x, y)) {
        final old = result[c.position];
        result[c.position] = _Control(
          c.position,
          (old?.weight ?? 0) + c.weight * weight,
          c.footprint,
        );
      }
    }
    if (result.length > 6) {
      throw StateError('Water stencil exceeds six controls.');
    }
    return List.unmodifiable(result.values);
  }

  List<_Control> vertex(OceanPatchId p, int i, int j) => _cache.putIfAbsent(
    (p, i, j),
    () {
      final n = surface.segments;
      final corner = (i == 0 || i == n) && (j == 0 || j == n);
      final side = j == 0
          ? OceanPatchSide.south
          : i == n
          ? OceanPatchSide.east
          : j == n
          ? OceanPatchSide.north
          : i == 0
          ? OceanPatchSide.west
          : null;
      if (!corner && side != null) {
        final t = switch (side) {
          OceanPatchSide.south => i / n,
          OceanPatchSide.east => j / n,
          OceanPatchSide.north => 1 - i / n,
          OceanPatchSide.west => 1 - j / n,
        };
        final other = surface.topology.across(p, side, t);
        if (other.level < p.level) {
          final uv = other.localCoordinates(p.cubePoint(i / n, j / n));
          return at(other, uv.u.clamp(0, 1), uv.v.clamp(0, 1));
        }
      }
      final cube = p.cubePoint(i / n, j / n);
      var level = p.level;
      // Identical control points receive the same conservative filter width on
      // either side of an edge or corner, including a cube-face boundary.
      for (final other in surface.topology.patches) {
        if (other.level >= level ||
            cube.dot(oceanCubeFaces[other.face].normal) <= 0) {
          continue;
        }
        final uv = other.localCoordinates(cube);
        if (uv.u >= -1e-10 &&
            uv.u <= 1 + 1e-10 &&
            uv.v >= -1e-10 &&
            uv.v <= 1 + 1e-10) {
          level = math.min(level, other.level);
        }
      }
      final ellipsoid = surface.ellipsoid;
      final footprint =
          2 *
          ellipsoid.maximumRadius *
          (ellipsoid.maximumRadius / ellipsoid.minimumRadius) /
          ((1 << level) * n);
      return [_Control(p.point(i / n, j / n, ellipsoid), 1, footprint)];
    },
  );
}
