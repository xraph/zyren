import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'cube_patch.dart';
import 'neighbours.dart';

final class OceanLodSettings {
  final double maxScreenError, hysteresis;
  final int maxPatches, maxVertices, segments, maxLevel;
  OceanLodSettings({
    required this.maxScreenError,
    required this.maxPatches,
    required this.maxVertices,
    this.hysteresis = .2,
    this.segments = 16,
    this.maxLevel = 20,
  }) {
    validateOceanSegments(segments);
    if (!maxScreenError.isFinite ||
        maxScreenError <= 0 ||
        !hysteresis.isFinite ||
        hysteresis <= 0 ||
        hysteresis >= 1 ||
        maxPatches < 6 ||
        maxPatches > 4096 ||
        maxLevel < 0 ||
        maxLevel > 20 ||
        maxVertices < 6 * verticesPerPatch ||
        maxVertices > 18000000) {
      throw ArgumentError('Invalid ocean LOD bounds.');
    }
  }
  int get verticesPerPatch => (segments + 1) * (segments + 1);
}

void validateOceanSegments(int segments) {
  if (segments < 4 || segments > 64 || (segments & (segments - 1)) != 0) {
    throw ArgumentError('Ocean grids require 4..64 power-of-two segments.');
  }
}

final class OceanSurfaceSelection {
  final List<OceanPatchId> allPatches, patches;
  final List<OceanSharedEdge> neighbourEdges;
  final int vertexCount;
  final bool budgetLimited;

  /// Curvature error estimate in physical pixels. Wave interpolation is separate.
  final double maximumScreenError;
  OceanSurfaceSelection._(
    Iterable<OceanPatchId> all,
    Iterable<OceanPatchId> visible,
    this.neighbourEdges,
    this.vertexCount,
    this.budgetLimited,
    this.maximumScreenError,
  ) : allPatches = List.unmodifiable(all),
      patches = List.unmodifiable(visible);
}

OceanSurfaceSelection selectOceanSurface(
  Camera camera,
  ViewportMetrics viewport,
  Ellipsoid ellipsoid,
  OceanLodSettings settings, {
  double displacementBoundMetres = 0,
}) => OceanSurfaceSelector(
  ellipsoid: ellipsoid,
  settings: settings,
).select(camera, viewport, displacementBoundMetres: displacementBoundMetres);

/// Retains a complete balanced cover. Culling only affects the drawable subset.
final class OceanSurfaceSelector {
  final Ellipsoid ellipsoid;
  final OceanLodSettings settings;
  Set<OceanPatchId> _leaves = {
    for (var face = 0; face < 6; face++)
      OceanPatchId(face: face, level: 0, x: 0, y: 0),
  };
  OceanSurfaceSelector({
    this.ellipsoid = Ellipsoid.wgs84,
    required this.settings,
  }) {
    validateOceanEllipsoid(ellipsoid);
  }

  OceanSurfaceSelection select(
    Camera camera,
    ViewportMetrics viewport, {
    double displacementBoundMetres = 0,
  }) {
    if (!viewport.isUsable ||
        !viewport.devicePixelRatio.isFinite ||
        viewport.devicePixelRatio <= 0 ||
        viewport.devicePixelRatio > 16 ||
        !camera.position.isFinite) {
      throw ArgumentError(
        'Ocean selection requires a finite camera and usable viewport.',
      );
    }
    // Validate even if every patch is culled.
    _leaves.first.bounds(
      ellipsoid,
      displacementBoundMetres: displacementBoundMetres,
    );
    final view = _View(
      camera,
      viewport,
      ellipsoid,
      settings.segments,
      displacementBoundMetres,
    );
    final leaves = Set<OceanPatchId>.of(_leaves);
    // Coarsening uses the lower threshold and must preserve neighbour balance.
    var changed = true;
    while (changed) {
      changed = false;
      final parents = leaves.map((p) => p.parent).nonNulls.toSet().toList()
        ..sort((a, b) => b.level.compareTo(a.level));
      for (final parent in parents) {
        if (!leaves.containsAll(parent.children) ||
            view.error(parent) >=
                settings.maxScreenError * (1 - settings.hysteresis)) {
          continue;
        }
        final candidate = Set<OceanPatchId>.of(leaves)
          ..removeAll(parent.children)
          ..add(parent);
        if (!_balanced(candidate)) continue;
        leaves
          ..clear()
          ..addAll(candidate);
        changed = true;
      }
    }
    final rejected = <OceanPatchId>{};
    while (true) {
      final candidates =
          leaves
              .where(
                (p) =>
                    !rejected.contains(p) &&
                    view.error(p) > settings.maxScreenError,
              )
              .toList()
            ..sort((a, b) {
              final order = view.error(b).compareTo(view.error(a));
              return order != 0 ? order : a.toString().compareTo(b.toString());
            });
      if (candidates.isEmpty) break;
      final candidate = Set<OceanPatchId>.of(leaves), patch = candidates.first;
      if (!_split(candidate, patch)) {
        rejected.add(patch);
        continue;
      }
      leaves
        ..clear()
        ..addAll(candidate);
    }
    final visible = leaves.where(view.visible).toList();
    final maximum = visible.fold(0.0, (v, p) => math.max(v, view.error(p)));
    final neighbours = OceanPatchNeighbours(leaves, ellipsoid: ellipsoid);
    _leaves = leaves;
    return OceanSurfaceSelection._(
      leaves,
      visible,
      neighbours.sharedEdges,
      leaves.length * settings.verticesPerPatch,
      maximum > settings.maxScreenError,
      maximum,
    );
  }

  bool _split(Set<OceanPatchId> leaves, OceanPatchId patch) {
    if (!leaves.contains(patch)) return true;
    if (patch.level >= settings.maxLevel || !_fits(leaves.length + 3)) {
      return false;
    }
    final neighbours = OceanPatchNeighbours(leaves, ellipsoid: ellipsoid);
    for (final side in OceanPatchSide.values) {
      for (final other in neighbours.adjacent(patch, side)) {
        if (other.level < patch.level && !_split(leaves, other)) return false;
      }
    }
    if (!_fits(leaves.length + 3)) return false;
    leaves
      ..remove(patch)
      ..addAll(patch.children);
    return true;
  }

  bool _fits(int count) =>
      count <= settings.maxPatches &&
      count * settings.verticesPerPatch <= settings.maxVertices;
  bool _balanced(Set<OceanPatchId> leaves) {
    final neighbours = OceanPatchNeighbours(leaves, ellipsoid: ellipsoid);
    return leaves.every(
      (p) => OceanPatchSide.values.every(
        (s) => (p.level - neighbours.across(p, s).level).abs() <= 1,
      ),
    );
  }
}

final class _View {
  final Camera camera;
  final ViewportMetrics viewport;
  final Ellipsoid ellipsoid;
  final int segments;
  final double displacement;
  late final frustum = Frustum.fromCamera(camera, viewport.aspect);
  final _visibility = <OceanPatchId, bool>{};
  final _errors = <OceanPatchId, double>{};
  _View(
    this.camera,
    this.viewport,
    this.ellipsoid,
    this.segments,
    this.displacement,
  );
  bool visible(OceanPatchId p) => _visibility.putIfAbsent(p, () {
    final b = p.bounds(ellipsoid, displacementBoundMetres: displacement);
    final r = Vec3(b.radius, b.radius, b.radius);
    if (!frustum.intersectsBounds(Bounds3(b.center - r, b.center + r))) {
      return false;
    }
    // A sphere wholly inside the shadow cone of the inscribed solid body is hidden.
    final eye = camera.position, distance = eye.length;
    final occluder = ellipsoid.minimumRadius - displacement;
    final delta = b.center - eye, d = delta.length;
    if (distance > occluder &&
        d > b.radius &&
        d - b.radius > math.sqrt(distance * distance - occluder * occluder)) {
      final cone = math.asin(occluder / distance),
          radius = math.asin(b.radius / d);
      final angle = math.acos((-eye / distance).dot(delta / d).clamp(-1, 1));
      if (angle + radius < cone) return false;
    }
    return true;
  });
  double error(OceanPatchId p) => _errors.putIfAbsent(p, () {
    if (!visible(p)) return 0;
    final big = ellipsoid.maximumRadius, small = ellipsoid.minimumRadius;
    // A conservative bound on the normalized cube map's second derivative,
    // enlarged fourfold for edges stitched to the next coarser level.
    final curvature =
        12 *
        big *
        big *
        big /
        (small * small) /
        (segments * segments * (1 << (2 * p.level)));
    final b = p.bounds(ellipsoid, displacementBoundMetres: displacement);
    final c = camera;
    if (c is OrthographicCamera) {
      return curvature *
          viewport.height *
          viewport.devicePixelRatio *
          c.zoom /
          (c.top - c.bottom);
    }
    if (c is! PerspectiveCamera) {
      throw UnsupportedError(
        'Ocean selection requires a perspective or orthographic camera.',
      );
    }
    return curvature *
        viewport.height *
        viewport.devicePixelRatio *
        c.zoom /
        (2 *
            math.tan(c.fieldOfView / 2) *
            math.max(.001, c.position.distanceTo(b.center) - b.radius));
  });
}
