part of '../zyren_interaction.dart';

/// A local point attached to an object. Labels and widgets share this projection.
final class SceneAnchor {
  final Object3D object;
  final Vec3 localPoint;
  final bool testOcclusion;
  const SceneAnchor(
    this.object, {
    this.localPoint = Vec3.zero,
    this.testOcclusion = false,
  });
}

enum AnchorVisibility {
  visible,
  detached,
  hidden,
  outsideViewport,
  occluded,
  unavailable,
}

final class AnchorProjection {
  final AnchorVisibility visibility;
  final ViewportPoint? point;
  final Vec3? worldPoint;
  final double? depth;
  const AnchorProjection(
    this.visibility, {
    this.point,
    this.worldPoint,
    this.depth,
  });
  bool get visible => visibility == AnchorVisibility.visible;
}

/// Projects in logical pixels. Optional occlusion uses CPU triangle geometry,
/// so transparent pixels and custom GPU displacement are not resolved here.
final class SceneAnchorProjector {
  final Scene scene;
  final Camera Function() camera;
  final ViewportMetrics Function() viewport;
  final _raycaster = Raycaster();
  bool _disposed = false;
  SceneAnchorProjector({
    required this.scene,
    required this.camera,
    required this.viewport,
  });
  AnchorProjection project(SceneAnchor anchor) {
    if (_disposed) throw StateError('Projector is disposed.');
    final size = viewport(), view = camera();
    if (!size.isUsable || !anchor.localPoint.isFinite) {
      return const AnchorProjection(AnchorVisibility.unavailable);
    }
    var matrix = Mat4.identity();
    final path = <Object3D>[];
    var member = false;
    for (Object3D? node = anchor.object; node != null; node = node.parent) {
      path.add(node);
      if (!node.visible) return const AnchorProjection(AnchorVisibility.hidden);
      if (identical(node, scene)) {
        member = true;
        break;
      }
    }
    if (!member) return const AnchorProjection(AnchorVisibility.detached);
    for (final node in path.reversed) {
      matrix = matrix * node.localMatrix;
    }
    final m = matrix.storage, p = anchor.localPoint;
    final world = Vec3(
      m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
      m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
      m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
    );
    if ((world - view.position).dot(view.target - view.position) <= 0) {
      return AnchorProjection(
        AnchorVisibility.outsideViewport,
        worldPoint: world,
      );
    }
    final projected = view.projectPoint(world, size.aspect);
    final point = ViewportPoint(
      (projected.x + 1) * size.width / 2,
      (1 - projected.y) * size.height / 2,
    );
    if (!projected.isFinite ||
        projected.z < 0 ||
        projected.z > 1 ||
        projected.x.abs() > 1 ||
        projected.y.abs() > 1 ||
        scene.clippingPlanes.any((plane) => plane.distanceTo(world) < 0)) {
      return AnchorProjection(
        AnchorVisibility.outsideViewport,
        worldPoint: world,
        depth: projected.z,
      );
    }
    if (anchor.testOcclusion) {
      final hit = _raycaster
          .captureFromCamera(
            scene,
            view,
            point,
            logicalWidth: size.width,
            logicalHeight: size.height,
          )
          .intersectFirst();
      if (hit != null) {
        var own = false;
        for (Object3D? node = hit.object; node != null; node = node.parent) {
          if (identical(node, anchor.object)) {
            own = true;
            break;
          }
        }
        if (!own &&
            (hit.point - view.position).length <
                (world - view.position).length - 1e-6) {
          return AnchorProjection(
            AnchorVisibility.occluded,
            point: point,
            worldPoint: world,
            depth: projected.z,
          );
        }
      }
    }
    return AnchorProjection(
      AnchorVisibility.visible,
      point: point,
      worldPoint: world,
      depth: projected.z,
    );
  }

  void dispose() {
    _disposed = true;
    _raycaster.clearCache();
  }
}
