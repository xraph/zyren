import 'dart:math' as math;
import 'dart:typed_data';
import '../geometry/geometry.dart';
import '../input/viewport_point.dart';
import '../math/mat4.dart';
import '../math/vec3.dart';
import '../rendering/scene_issue.dart';
import '../scene/layer_mask.dart';
import '../scene/scene.dart';
import '../rendering/depth_strategy.dart';
import 'bounds.dart';
import 'ray.dart';
part 'bvh.dart';

/// Controls how a captured query finds candidate triangles.
enum RaycastAcceleration {
  /// Reuse revisioned geometry and scene bounding volume hierarchies.
  bvh,

  /// Test every candidate mesh and triangle without building spatial trees.
  none,
}

/// CPU triangle queries. Captures retain immutable geometry and pose revisions.
/// Texture alpha, line/point footprints and custom vertex shader displacement
/// are not evaluated; material sidedness and built-in deformation are applied.
final class Raycaster {
  final double near, far;
  final LayerMask layers;
  final RaycastAcceleration acceleration;
  var _scenes = Expando<_SceneBvh>();
  var _geometry = Expando<_GeometryBvh>();
  var _poses = Expando<_GeometryBvh>();

  /// Releases reusable indices. Requests already captured keep their versions.
  void clearCache() {
    _scenes = Expando<_SceneBvh>();
    _geometry = Expando<_GeometryBvh>();
    _poses = Expando<_GeometryBvh>();
  }

  Raycaster({
    this.near = 0,
    this.far = double.infinity,
    this.layers = LayerMask.all,
    this.acceleration = RaycastAcceleration.bvh,
  }) {
    if (!near.isFinite || near < 0 || far.isNaN || far < near) {
      throw ArgumentError('Ray limits require 0 <= near <= far.');
    }
  }

  List<PickResult> intersectScene(
    Scene scene,
    CameraRay ray, {
    double near = 0,
    double far = double.infinity,
  }) => _guard(
    () => Raycaster(
      near: near,
      far: far,
      layers: layers,
      acceleration: acceleration,
    ).capture(scene, Ray(ray.origin, ray.direction)).intersectAll(),
  );

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
    final a = _project(
      inverse,
      Vec3(
        ndc.x,
        ndc.y,
        camera.depthStrategy == DepthStrategy.reversed ? 1 : 0,
      ),
    );
    final b = _project(
      inverse,
      Vec3(
        ndc.x,
        ndc.y,
        camera.depthStrategy == DepthStrategy.reversed ? 0 : 1,
      ),
    );
    final direction = (b - a).normalized();
    final forward = (camera.target - camera.position).normalized();
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
        null,
        _RaycastCounters().freeze(),
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
    final stats = _RaycastCounters();
    final cached = _scenes[scene];
    if (cached != null &&
        cached.revision == scene.revision &&
        cached.layers == layers) {
      return RaycastSnapshot._(
        ray,
        scene.revision,
        near,
        far,
        cached.meshes,
        cached.tree,
        stats.freeze(),
      );
    }
    // Keep the loop baseline non-null. Dart 3.13.4 AOT can hoist nullable
    // baseline field loads ahead of a guard inside this recursive visitor.
    final previousMeshes = cached?.meshes ?? const <_PickMesh>[];
    final meshes = <_PickMesh>[];
    void visit(Object3D node, Mat4 parent, bool parentClipping) {
      final clipping = parentClipping && node.clippingEnabled;
      final planes = clipping ? scene.clippingPlanes : const <ClippingPlane>[];
      if (!node.visible) return;
      final world = parent * node.localMatrix;
      if (node is Mesh &&
          !node.fragmentCoverage.isEmpty &&
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
        _GeometryBvh? index;
        if (acceleration == RaycastAcceleration.bvh) {
          final cache = pose == null ? _geometry : _poses;
          final Object key = pose == null ? node.geometry : node;
          index = _GeometryBvh.update(geometry, pose, cache[key], stats);
          cache[key] = index;
        }
        final bounds =
            pose?.bounds ??
            Bounds3(geometry.bounds.minimum, geometry.bounds.maximum);
        final instances = node is InstancedMesh
            ? node.captureInstances()
            : null;
        final count = node is InstancedMesh ? node.count : 1;
        for (var i = 0; i < count; i++) {
          final instance = instances?.transforms[i];
          final old = meshes.length < previousMeshes.length
              ? previousMeshes[meshes.length]
              : null;
          final Mat4 model, inverse;
          if (old == null ||
              !identical(old.object, node) ||
              old.instanceIndex != (instance == null ? null : i) ||
              old.meshWorld != world ||
              old.instanceTransform != instance) {
            model = instance == null ? world : world * instance;
            inverse = model.inverted();
            stats.modelMatrixInversions++;
          } else {
            if (identical(old.geometry, geometry) &&
                identical(old.pose, pose) &&
                old.side == node.material.side &&
                _samePlanes(old.clippingPlanes, planes)) {
              meshes.add(old);
              continue;
            }
            model = old.model;
            inverse = old.inverse;
          }
          meshes.add(
            _PickMesh(
              meshes.length,
              index,
              node,
              geometry,
              pose,
              model,
              inverse,
              bounds,
              node.material.side,
              instance == null ? null : i,
              world,
              instance,
              List.unmodifiable(planes),
            ),
          );
        }
      }
      for (final child in node.children) {
        visit(child, world, clipping);
      }
    }

    visit(scene, Mat4.identity(), true);
    final frozen = List<_PickMesh>.unmodifiable(meshes);
    _BoundsBvh? tree;
    final sameObjects =
        cached != null &&
        cached.meshes.length == frozen.length &&
        Iterable<int>.generate(frozen.length).every(
          (i) =>
              identical(cached.meshes[i].object, frozen[i].object) &&
              cached.meshes[i].instanceIndex == frozen[i].instanceIndex,
        );
    if (acceleration == RaycastAcceleration.bvh) {
      final bounds = [for (final mesh in meshes) mesh.worldBounds];
      if (sameObjects && cached.tree != null) {
        tree = cached.tree!.refit(bounds);
        stats.sceneRefits++;
      } else {
        tree = _BoundsBvh(bounds);
        stats.sceneBuilds++;
      }
    }
    _scenes[scene] = _SceneBvh(scene.revision, layers, frozen, tree);
    return RaycastSnapshot._(
      ray,
      scene.revision,
      near,
      far,
      frozen,
      tree,
      stats.freeze(),
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
  final _BoundsBvh? _tree;
  final RaycastStatistics _captureStats;
  RaycastSnapshot._(
    this.ray,
    this.sceneRevision,
    this._near,
    this._far,
    this._meshes,
    this._tree,
    this._captureStats,
  );

  PickResult? intersectFirst() => trace().hits.firstOrNull;

  /// Nearest first. Ties retain scene traversal, instance and triangle order.
  List<PickResult> intersectAll() => trace(firstHitOnly: false).hits;

  /// Captured build/refit work and exact tests performed by this query.
  RaycastReport trace({bool firstHitOnly = true}) => _guard(() {
    final stats = _RaycastCounters.from(_captureStats);
    final hits = <(int, PickResult)>[];
    var limit = _far;
    int compare((int, PickResult) a, (int, PickResult) b) {
      final distance = a.$2.distance.compareTo(b.$2.distance);
      if (distance != 0) return distance;
      final mesh = a.$1.compareTo(b.$1);
      return mesh == 0
          ? a.$2.triangleIndex.compareTo(b.$2.triangleIndex)
          : mesh;
    }

    void receive(int order, PickResult hit) {
      final entry = (order, hit);
      if (!firstHitOnly) {
        hits.add(entry);
      } else if (hits.isEmpty || compare(entry, hits.first) < 0) {
        if (hits.isNotEmpty) hits.clear();
        hits.add(entry);
        limit = hit.distance;
      }
    }

    void meshHit(int meshIndex) {
      final mesh = _meshes[meshIndex];
      stats.meshTests++;
      final direction = _direction(mesh.inverse, ray.direction);
      final local = Ray(_project(mesh.inverse, ray.origin), direction);
      if (local.intersectBounds(mesh.bounds) == null) return;
      final indices = mesh.geometry.indices;
      void triangleHit(int triangle) {
        final i = triangle * 3;
        final a = indices[i], b = indices[i + 1], c = indices[i + 2];
        stats.triangleTests++;
        final hit = local.intersectTriangle(
          mesh.vertex(a),
          mesh.vertex(b),
          mesh.vertex(c),
          side: mesh.side,
        );
        if (hit == null) return;
        final point = _project(mesh.model, hit.point);
        // Local distances change under nonuniform scaling. Sort in world space.
        final distance = point.distanceTo(ray.origin);
        if (!distance.isFinite) {
          throw ArgumentError('Intersection distance is not finite.');
        }
        if (distance < _near || distance > _far) return;
        if (mesh.clippingPlanes.any((plane) => plane.distanceTo(point) < 0)) {
          return;
        }
        final weights = hit.barycentric, uv = mesh.geometry.uv0;
        final localNormal = (mesh.vertex(b) - mesh.vertex(a))
            .cross(mesh.vertex(c) - mesh.vertex(a))
            .normalized();
        final n = mesh.inverse.storage;
        final normal = Vec3(
          n[0] * localNormal.x + n[1] * localNormal.y + n[2] * localNormal.z,
          n[4] * localNormal.x + n[5] * localNormal.y + n[6] * localNormal.z,
          n[8] * localNormal.x + n[9] * localNormal.y + n[10] * localNormal.z,
        ).normalized();
        final uv1 = mesh.geometry.uv1;
        receive(
          mesh.order,
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
            normal: normal,
            uv1: uv1 == null
                ? null
                : (
                    u:
                        uv1[a * 2] * weights.x +
                        uv1[b * 2] * weights.y +
                        uv1[c * 2] * weights.z,
                    v:
                        uv1[a * 2 + 1] * weights.x +
                        uv1[b * 2 + 1] * weights.y +
                        uv1[c * 2 + 1] * weights.z,
                  ),
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

      if (mesh.index case final index?) {
        index.tree.visit(
          local,
          () => limit * direction.length,
          triangleHit,
          stats,
        );
      } else {
        for (var i = 0; i < indices.length ~/ 3; i++) {
          triangleHit(i);
        }
      }
    }

    if (_tree case final tree?) {
      tree.visit(ray, () => limit, meshHit, stats);
    } else {
      for (var i = 0; i < _meshes.length; i++) {
        meshHit(i);
      }
    }
    hits.sort(compare);
    return RaycastReport._(
      List.unmodifiable(hits.map((hit) => hit.$2)),
      stats.freeze(),
    );
  });
}

/// Read-only counters, including build work captured before query execution.
final class RaycastStatistics {
  /// New triangle trees built during capture.
  final int geometryBuilds;

  /// Existing triangle partitions updated for geometry or pose changes.
  final int geometryRefits;

  /// New mesh/instance trees built during capture.
  final int sceneBuilds;

  /// Existing mesh/instance partitions updated during capture.
  final int sceneRefits;

  /// Mesh/instance inverses computed here, excluding camera and skin work.
  final int modelMatrixInversions;

  /// Candidate mesh/instance records visited by this traversal.
  final int meshTests;

  /// Tree-node bounds tested, excluding candidate mesh-local bounds.
  final int bvhBoundsTests;

  /// Exact ray/triangle tests performed by this traversal.
  final int triangleTests;
  const RaycastStatistics._(
    this.geometryBuilds,
    this.geometryRefits,
    this.sceneBuilds,
    this.sceneRefits,
    this.modelMatrixInversions,
    this.meshTests,
    this.bvhBoundsTests,
    this.triangleTests,
  );
}

/// Sorted captured hits and the work recorded for one traversal.
final class RaycastReport {
  final List<PickResult> hits;
  final RaycastStatistics statistics;
  const RaycastReport._(this.hits, this.statistics);
}

final class PickResult {
  final Mesh object;
  final Vec3 point, normal, barycentric;

  /// Frozen world-space triangle vertices, in index order.
  final List<Vec3> triangle;
  final double distance;
  final int triangleIndex, sceneRevision;
  final int? instanceIndex;
  final ({double u, double v})? uv, uv1;
  const PickResult._({
    required this.object,
    required this.point,
    required this.normal,
    required this.uv1,
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
  final int order;
  final _GeometryBvh? index;
  final Mesh object;
  final GeometrySnapshot geometry;
  final DeformationSnapshot? pose;
  final Mat4 model, inverse;
  final Bounds3 bounds;
  final List<ClippingPlane> clippingPlanes;
  final Mat4 meshWorld;
  final Mat4? instanceTransform;
  late final Bounds3 worldBounds = bounds.transformed(model);
  final MaterialSide side;
  final int? instanceIndex;
  _PickMesh(
    this.order,
    this.index,
    this.object,
    this.geometry,
    this.pose,
    this.model,
    this.inverse,
    this.bounds,
    this.side,
    this.instanceIndex,
    this.meshWorld,
    this.instanceTransform,
    this.clippingPlanes,
  );
  Vec3 vertex(int index) {
    if (this.index case final tree?) {
      return Vec3.array(tree.positions, index * 3);
    }
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

bool _samePlanes(List<ClippingPlane> a, List<ClippingPlane> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => identical(a[i], b[i]));
