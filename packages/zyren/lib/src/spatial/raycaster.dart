import 'dart:math' as math;
import '../geometry/geometry.dart';
import '../math/mat4.dart';
import '../math/vec3.dart';
import '../rendering/scene_issue.dart';
import '../scene/scene.dart';

/// Finite, inclusive axis-aligned bounds. A flat axis is valid.
final class Bounds3 {
  final Vec3 min, max;
  Bounds3(this.min, this.max) {
    if (!min.isFinite ||
        !max.isFinite ||
        min.x > max.x ||
        min.y > max.y ||
        min.z > max.z) {
      throw ArgumentError('Bounds require finite, ordered coordinates.');
    }
  }

  /// Entry and exit distances along a normalized world ray.
  ({double near, double far})? intersectRay(
    CameraRay ray, {
    double near = 0,
    double far = double.infinity,
  }) {
    _checkRange(near, far);
    return _intersect(ray.origin, ray.direction, near, far);
  }

  ({double near, double far})? _intersect(
    Vec3 origin,
    Vec3 direction,
    double near,
    double far,
  ) {
    for (var axis = 0; axis < 3; axis++) {
      final o = _axis(origin, axis), d = _axis(direction, axis);
      final low = _axis(min, axis), high = _axis(max, axis);
      if (d == 0) {
        if (o < low || o > high) return null;
        continue;
      }
      var start = (low - o) / d, end = (high - o) / d;
      if (start > end) {
        final swap = start;
        start = end;
        end = swap;
      }
      near = math.max(near, start);
      far = math.min(far, end);
      if (near > far) return null;
    }
    return (near: near, far: far);
  }
}

/// A hit captured at query time. [object] remains a live scene object.
final class PickResult {
  final Mesh object;
  final Vec3 point;

  /// World-space face normal, transformed by the inverse transpose.
  /// The normal retains the geometry's orientation on either material side.
  final Vec3 normal;
  final double distance;
  final int triangleIndex, sceneRevision;
  final Vec3 barycentric;
  final ({double u, double v})? uv, uv1;

  /// Stable slot in an InstancedMesh, or null for an ordinary mesh.
  final int? instanceIndex;
  const PickResult._({
    required this.object,
    this.instanceIndex,
    required this.point,
    required this.normal,
    required this.distance,
    required this.triangleIndex,
    required this.sceneRevision,
    required this.barycentric,
    required this.uv,
    required this.uv1,
  });
}

/// CPU triangle picking with the renderer's visibility and material sidedness.
/// Trees are cached weakly by geometry revision; transforms are read each query.
/// Line and point geometry are skipped, while their children are still visited.
final class Raycaster {
  final _trees = Expando<_GeometryTree>('picking geometry');

  List<PickResult> intersectScene(
    Scene scene,
    CameraRay ray, {
    double near = 0,
    double far = double.infinity,
  }) {
    _checkRange(near, far);
    final revision = scene.revision;
    final hits = <PickResult>[];
    final objectOrder = <Mesh, int>{};
    void visit(Object3D node, Mat4 parent) {
      if (!node.visible) return;
      final world = parent * node.localMatrix;
      if (node is Mesh &&
          node.geometry.topology == GeometryTopology.triangles) {
        objectOrder[node] = objectOrder.length;
        for (
          var slot = 0;
          slot < (node is InstancedMesh ? node.count : 1);
          slot++
        ) {
          final instanceWorld = node is InstancedMesh
              ? world * node.transformAt(slot)
              : world;
          final inverse = instanceWorld.inverted();
          final translation = Vec3(
            instanceWorld.storage[12],
            instanceWorld.storage[13],
            instanceWorld.storage[14],
          );
          // Subtract the origin before applying the inverse linear transform to
          // keep planetary translation out of the small local intersection math.
          final origin = _vector(inverse, ray.origin - translation);
          final direction = _vector(inverse, ray.direction);
          if (!origin.isFinite ||
              !direction.isFinite ||
              direction.length2 == 0) {
            throw ArgumentError(
              'Mesh transform cannot represent the picking ray.',
            );
          }
          var tree = _trees[node.geometry];
          if (tree == null || tree.revision != node.geometry.revision) {
            tree = _trees[node.geometry] = _GeometryTree(node.geometry);
          }
          tree.intersect(origin, direction, near, far, node.material.side, (
            triangle,
            distance,
            weights,
            localNormal,
          ) {
            final point = ray.at(distance);
            final m = inverse.storage;
            final normal = Vec3(
              m[0] * localNormal.x +
                  m[1] * localNormal.y +
                  m[2] * localNormal.z,
              m[4] * localNormal.x +
                  m[5] * localNormal.y +
                  m[6] * localNormal.z,
              m[8] * localNormal.x +
                  m[9] * localNormal.y +
                  m[10] * localNormal.z,
            ).normalized();
            if (!point.isFinite) {
              throw ArgumentError('Intersection is not finite.');
            }
            hits.add(
              PickResult._(
                object: node,
                instanceIndex: node is InstancedMesh ? slot : null,
                point: point,
                normal: normal,
                distance: distance,
                triangleIndex: triangle,
                sceneRevision: revision,
                barycentric: weights,
                uv: _uv(node.geometry, node.geometry.uv0, triangle, weights),
                uv1: _uv(node.geometry, node.geometry.uv1, triangle, weights),
              ),
            );
          });
        }
      }
      for (final child in node.children) {
        visit(child, world);
      }
    }

    try {
      visit(scene, Mat4.identity());
    } on ArgumentError catch (error) {
      throw _invalid('Scene transforms cannot be used for picking.', error);
    }
    hits.sort((a, b) {
      final distance = a.distance.compareTo(b.distance);
      if (distance != 0) return distance;
      final order = objectOrder[a.object]!.compareTo(objectOrder[b.object]!);
      if (order != 0) return order;
      final instance = (a.instanceIndex ?? -1).compareTo(b.instanceIndex ?? -1);
      return instance != 0
          ? instance
          : a.triangleIndex.compareTo(b.triangleIndex);
    });
    return List.unmodifiable(hits);
  }
}

typedef _Hit =
    void Function(int triangle, double distance, Vec3 weights, Vec3 normal);

final class _Node {
  final Bounds3 bounds;
  final int start, end;
  final _Node? left, right;
  _Node(this.bounds, this.start, this.end, [this.left, this.right]);
}

final class _GeometryTree {
  final BufferGeometry geometry;
  final int revision;
  late final List<int> order = List.generate(
    geometry.indices.length ~/ 3,
    (i) => i,
  );
  late final _Node root = _build(0, order.length);
  _GeometryTree(this.geometry) : revision = geometry.revision;
  Vec3 vertex(int triangle, int corner) => Vec3.array(
    geometry.positions,
    geometry.indices[triangle * 3 + corner] * 3,
  );

  _Node _build(int start, int end) {
    var low = vertex(order[start], 0), high = low;
    for (var i = start; i < end; i++) {
      for (var corner = 0; corner < 3; corner++) {
        final v = vertex(order[i], corner);
        low = Vec3(
          math.min(low.x, v.x),
          math.min(low.y, v.y),
          math.min(low.z, v.z),
        );
        high = Vec3(
          math.max(high.x, v.x),
          math.max(high.y, v.y),
          math.max(high.z, v.z),
        );
      }
    }
    final bounds = Bounds3(low, high);
    if (end - start <= 8) return _Node(bounds, start, end);
    final size = high - low;
    var axis = size.x >= size.y ? 0 : 1;
    if (size.z > _axis(size, axis)) axis = 2;
    double center(int triangle) =>
        _axis(vertex(triangle, 0), axis) / 3 +
        _axis(vertex(triangle, 1), axis) / 3 +
        _axis(vertex(triangle, 2), axis) / 3;
    final sorted = order.sublist(start, end)
      ..sort((a, b) {
        final comparison = center(a).compareTo(center(b));
        return comparison == 0 ? a.compareTo(b) : comparison;
      });
    order.setRange(start, end, sorted);
    final middle = (start + end) ~/ 2;
    return _Node(
      bounds,
      start,
      end,
      _build(start, middle),
      _build(middle, end),
    );
  }

  void intersect(
    Vec3 origin,
    Vec3 direction,
    double near,
    double far,
    MaterialSide side,
    _Hit hit,
  ) {
    void visit(_Node node) {
      if (node.bounds._intersect(origin, direction, near, far) == null) return;
      if (node.left != null) {
        visit(node.left!);
        visit(node.right!);
        return;
      }
      for (var i = node.start; i < node.end; i++) {
        final triangle = order[i];
        final a = vertex(triangle, 0);
        final edge1 = vertex(triangle, 1) - a, edge2 = vertex(triangle, 2) - a;
        final cross = direction.cross(edge2);
        final determinant = edge1.dot(cross);
        if (determinant == 0 ||
            (side == MaterialSide.front && determinant < 0) ||
            (side == MaterialSide.back && determinant > 0)) {
          continue;
        }
        final offset = origin - a;
        final u = offset.dot(cross) / determinant;
        if (u < 0 || u > 1) continue;
        final q = offset.cross(edge1);
        final v = direction.dot(q) / determinant;
        if (v < 0 || u + v > 1) continue;
        // Keep the inverse-transformed direction unnormalized: t still measures
        // distance along the original normalized world ray under any scale.
        final distance = edge2.dot(q) / determinant;
        if (!distance.isFinite || !u.isFinite || !v.isFinite) {
          throw ArgumentError('Triangle intersection exceeds numeric range.');
        }
        if (distance < near || distance > far) continue;
        hit(triangle, distance, Vec3(1 - u - v, u, v), edge1.cross(edge2));
      }
    }

    visit(root);
  }
}

({double u, double v})? _uv(
  BufferGeometry geometry,
  List<double>? values,
  int triangle,
  Vec3 weights,
) {
  if (values == null) return null;
  final a = geometry.indices[triangle * 3] * 2;
  final b = geometry.indices[triangle * 3 + 1] * 2;
  final c = geometry.indices[triangle * 3 + 2] * 2;
  return (
    u: values[a] * weights.x + values[b] * weights.y + values[c] * weights.z,
    v:
        values[a + 1] * weights.x +
        values[b + 1] * weights.y +
        values[c + 1] * weights.z,
  );
}

Vec3 _vector(Mat4 matrix, Vec3 v) {
  final m = matrix.storage;
  return Vec3(
    m[0] * v.x + m[4] * v.y + m[8] * v.z,
    m[1] * v.x + m[5] * v.y + m[9] * v.z,
    m[2] * v.x + m[6] * v.y + m[10] * v.z,
  );
}

double _axis(Vec3 value, int axis) => switch (axis) {
  0 => value.x,
  1 => value.y,
  _ => value.z,
};
void _checkRange(double near, double far) {
  if (!near.isFinite || near < 0 || far.isNaN || far < near) {
    throw _invalid(
      'Pick distances require finite nonnegative near and far >= near.',
    );
  }
}

SceneException _invalid(String message, [Object? cause]) => SceneException(
  SceneIssue(
    code: SceneIssueCodes.invalidPickRequest,
    message: message,
    operation: 'pick',
    cause: cause,
  ),
);
