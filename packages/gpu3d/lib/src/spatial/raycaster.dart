import 'dart:math' as math;
import '../geometry/geometry.dart';
import '../input/viewport_point.dart';
import '../math/mat4.dart';
import '../math/vec3.dart';
import '../rendering/scene_issue.dart';
import '../scene/layer_mask.dart';
import '../scene/scene.dart';
import 'bounds.dart';
import 'ray.dart';

/// CPU triangle queries. Captures retain immutable geometry and pose revisions.
/// Texture alpha, line/point footprints and custom vertex shader displacement
/// are not evaluated; material sidedness and built-in deformation are applied.
final class Raycaster {
  final double near, far;
  final LayerMask layers;
  Raycaster({
    this.near = 0,
    this.far = double.infinity,
    this.layers = LayerMask.all,
  }) {
    if (!near.isFinite || near < 0 || far.isNaN || far < near) {
      throw ArgumentError('Ray limits require 0 <= near <= far.');
    }
  }

  RaycastSnapshot capture(Scene scene, Ray ray) =>
      _guard(() => _capture(scene, ray, near, far, layers));

  /// Captures before returning. Points and extents are viewport-local logical
  /// pixels, regardless of device pixel ratio or render resolution scale.
  RaycastSnapshot captureFromCamera(
    Scene scene,
    Camera camera,
    ViewportPoint point, {
    required double logicalWidth,
    required double logicalHeight,
  }) => _guard(() {
    final ndc = point.toNdc(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
    );
    final aspect = logicalWidth / logicalHeight;
    final projection = camera.projectionMatrix(aspect);
    final inverse = camera.viewProjection(aspect).inverted();
    final a = _project(inverse, Vec3(ndc.x, ndc.y, 0));
    final b = _project(inverse, Vec3(ndc.x, ndc.y, 1));
    final direction = (b - a).normalized();
    final forward =
        (_project(inverse, const Vec3(0, 0, 1)) - _project(inverse, Vec3.zero))
            .normalized();
    // Perspective rays start at the eye. Orthographic rays start on the
    // camera plane, preserving their lateral offset and world distance.
    final origin = projection.storage[15] == 0
        ? Vec3.zero
        : a - direction * (a.dot(forward) / direction.dot(forward));
    final ray = Ray(camera.position + origin, direction);
    final minDistance = math.max(near, (a - origin).dot(direction));
    final maxDistance = math.min(far, (b - origin).dot(direction));
    final mask = layers.intersection(camera.layers);
    if (ndc.x < -1 ||
        ndc.x > 1 ||
        ndc.y < -1 ||
        ndc.y > 1 ||
        maxDistance < minDistance) {
      return RaycastSnapshot._(
        ray,
        scene.revision,
        minDistance,
        maxDistance,
        const [],
      );
    }
    return _capture(scene, ray, minDistance, maxDistance, mask);
  });

  RaycastSnapshot _capture(
    Scene scene,
    Ray ray,
    double near,
    double far,
    LayerMask layers,
  ) {
    final meshes = <_PickMesh>[];
    void visit(Object3D node, Mat4 parent) {
      if (!node.visible) return;
      final world = parent * node.localMatrix;
      if (node is Mesh &&
          node.layers.intersects(layers) &&
          node.geometry.topology == GeometryTopology.triangles &&
          (node is! InstancedMesh || node.count > 0)) {
        if (node is SkinnedMesh) {
          for (final joint in node.skin.joints) {
            Object3D? owner = joint;
            while (owner != null && !identical(owner, scene)) {
              owner = owner.parent;
            }
            if (owner == null) {
              throw ArgumentError(
                'Skin joints must belong to the queried scene.',
              );
            }
          }
        }
        final pose = node.captureDeformation();
        final geometry = node.geometry.capture();
        final bounds =
            pose?.bounds ??
            Bounds3(geometry.bounds.minimum, geometry.bounds.maximum);
        final instances = node is InstancedMesh
            ? node.captureInstances()
            : null;
        final count = node is InstancedMesh ? node.count : 1;
        for (var i = 0; i < count; i++) {
          final model = instances == null
              ? world
              : world * instances.transforms[i];
          meshes.add(
            _PickMesh(
              node,
              geometry,
              pose,
              model,
              model.inverted(),
              bounds,
              node.material.side,
              instances == null ? null : i,
            ),
          );
        }
      }
      for (final child in node.children) {
        visit(child, world);
      }
    }

    visit(scene, Mat4.identity());
    return RaycastSnapshot._(
      ray,
      scene.revision,
      near,
      far,
      List.unmodifiable(meshes),
    );
  }
}

/// An immutable request. [PickResult.object] identifies the live mesh; every
/// numeric result comes from the transforms, geometry and pose captured here.
final class RaycastSnapshot {
  final Ray ray;
  final int sceneRevision;
  final double _near, _far;
  final List<_PickMesh> _meshes;
  RaycastSnapshot._(
    this.ray,
    this.sceneRevision,
    this._near,
    this._far,
    this._meshes,
  );

  PickResult? intersectFirst() => _guard(() {
    PickResult? nearest;
    _intersect((hit) {
      if (nearest == null || hit.distance < nearest!.distance) nearest = hit;
    });
    return nearest;
  });

  /// Nearest first. Ties retain scene traversal, instance and triangle order.
  List<PickResult> intersectAll() => _guard(() {
    final hits = <(int, PickResult)>[];
    _intersect((hit) => hits.add((hits.length, hit)));
    hits.sort((a, b) {
      final distance = a.$2.distance.compareTo(b.$2.distance);
      return distance == 0 ? a.$1.compareTo(b.$1) : distance;
    });
    return List.unmodifiable(hits.map((hit) => hit.$2));
  });

  void _intersect(void Function(PickResult) receive) {
    for (final mesh in _meshes) {
      final local = Ray(
        _project(mesh.inverse, ray.origin),
        _direction(mesh.inverse, ray.direction),
      );
      if (local.intersectBounds(mesh.bounds) == null) continue;
      final indices = mesh.geometry.indices;
      for (var i = 0; i < indices.length; i += 3) {
        final a = indices[i], b = indices[i + 1], c = indices[i + 2];
        final hit = local.intersectTriangle(
          mesh.vertex(a),
          mesh.vertex(b),
          mesh.vertex(c),
          side: mesh.side,
        );
        if (hit == null) continue;
        final point = _project(mesh.model, hit.point);
        // Local distances change under nonuniform scaling. Sort in world space.
        final distance = point.distanceTo(ray.origin);
        if (!distance.isFinite) {
          throw ArgumentError('Intersection distance is not finite.');
        }
        if (distance < _near || distance > _far) continue;
        final weights = hit.barycentric, uv = mesh.geometry.uv0;
        receive(
          PickResult._(
            object: mesh.object,
            point: point,
            distance: distance,
            triangleIndex: i ~/ 3,
            instanceIndex: mesh.instanceIndex,
            triangle: List.unmodifiable([
              _project(mesh.model, mesh.vertex(a)),
              _project(mesh.model, mesh.vertex(b)),
              _project(mesh.model, mesh.vertex(c)),
            ]),
            barycentric: weights,
            sceneRevision: sceneRevision,
            uv: uv == null
                ? null
                : (
                    u:
                        uv[a * 2] * weights.x +
                        uv[b * 2] * weights.y +
                        uv[c * 2] * weights.z,
                    v:
                        uv[a * 2 + 1] * weights.x +
                        uv[b * 2 + 1] * weights.y +
                        uv[c * 2 + 1] * weights.z,
                  ),
          ),
        );
      }
    }
  }
}

final class PickResult {
  final Mesh object;
  final Vec3 point, barycentric;

  /// Frozen world-space triangle vertices, in index order.
  final List<Vec3> triangle;
  final double distance;
  final int triangleIndex, sceneRevision;
  final int? instanceIndex;
  final ({double u, double v})? uv;
  const PickResult._({
    required this.object,
    required this.point,
    required this.distance,
    required this.triangle,
    required this.triangleIndex,
    required this.instanceIndex,
    required this.barycentric,
    required this.sceneRevision,
    required this.uv,
  });
}

final class _PickMesh {
  final Mesh object;
  final GeometrySnapshot geometry;
  final DeformationSnapshot? pose;
  final Mat4 model, inverse;
  final Bounds3 bounds;
  final MaterialSide side;
  final int? instanceIndex;
  _PickMesh(
    this.object,
    this.geometry,
    this.pose,
    this.model,
    this.inverse,
    this.bounds,
    this.side,
    this.instanceIndex,
  );
  Vec3 vertex(int index) {
    if (pose != null) return pose!.vertexPosition(index);
    final p = geometry.positions, i = index * 3;
    return Vec3(p[i], p[i + 1], p[i + 2]);
  }
}

Vec3 _project(Mat4 matrix, Vec3 point) {
  final m = matrix.storage, x = point.x, y = point.y, z = point.z;
  final w = m[3] * x + m[7] * y + m[11] * z + m[15];
  final result = Vec3(
    (m[0] * x + m[4] * y + m[8] * z + m[12]) / w,
    (m[1] * x + m[5] * y + m[9] * z + m[13]) / w,
    (m[2] * x + m[6] * y + m[10] * z + m[14]) / w,
  );
  if (w == 0 || !result.isFinite) {
    throw ArgumentError('Projection must produce a finite point.');
  }
  return result;
}

Vec3 _direction(Mat4 matrix, Vec3 direction) {
  final m = matrix.storage, x = direction.x, y = direction.y, z = direction.z;
  return Vec3(
    m[0] * x + m[4] * y + m[8] * z,
    m[1] * x + m[5] * y + m[9] * z,
    m[2] * x + m[6] * y + m[10] * z,
  );
}

T _guard<T>(T Function() operation) {
  try {
    return operation();
  } on ArgumentError catch (error) {
    throw SceneException(
      SceneIssue(
        code: SceneIssueCodes.invalidPickRequest,
        message: 'Cannot pick this scene: $error',
        operation: 'pick',
        cause: error,
      ),
    );
  }
}
