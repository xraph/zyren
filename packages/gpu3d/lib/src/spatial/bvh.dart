part of 'raycaster.dart';

/// Immutable median-split bounds. Refit preserves partitions, never old bounds.
final class _BoundsBvh {
  final _BvhNode? root;
  _BoundsBvh._(this.root);
  factory _BoundsBvh(List<Bounds3> bounds) {
    final items = List.generate(bounds.length, (i) => i);
    final centers = [for (final box in bounds) box.center];
    _BvhNode build(int start, int end) {
      final box = _enclose(bounds, items, start, end);
      if (end - start <= 8) {
        return _BvhNode(box, List.unmodifiable(items.sublist(start, end)));
      }
      final size = box.size;
      final axis = size.x >= size.y && size.x >= size.z
          ? 0
          : size.y >= size.z
          ? 1
          : 2;
      double coordinate(int i) => switch (axis) {
        0 => centers[i].x,
        1 => centers[i].y,
        _ => centers[i].z,
      };
      int compare(int a, int b) {
        final order = coordinate(a).compareTo(coordinate(b));
        return order == 0 ? a.compareTo(b) : order;
      }

      final middle = (start + end) ~/ 2;
      // Partition at the median without sorting either child. Bound worst-case
      // work for adversarial orderings with a small partition budget.
      var low = start, high = end - 1, budget = 32;
      while (low < high) {
        if (budget-- == 0) {
          final sorted = items.sublist(low, high + 1)..sort(compare);
          items.setRange(low, high + 1, sorted);
          break;
        }
        final pivot = items[(low + high) ~/ 2];
        var left = low, right = high;
        while (left <= right) {
          while (compare(items[left], pivot) < 0) {
            left++;
          }
          while (compare(items[right], pivot) > 0) {
            right--;
          }
          if (left <= right) {
            final value = items[left];
            items[left++] = items[right];
            items[right--] = value;
          }
        }
        if (middle <= right) {
          high = right;
        } else if (middle >= left) {
          low = left;
        } else {
          break;
        }
      }
      return _BvhNode(box, null, build(start, middle), build(middle, end));
    }

    return _BoundsBvh._(bounds.isEmpty ? null : build(0, items.length));
  }

  static Bounds3 _enclose(
    List<Bounds3> bounds,
    List<int> items,
    int start,
    int end,
  ) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity,
        maxY = double.negativeInfinity,
        maxZ = double.negativeInfinity;
    for (var j = start; j < end; j++) {
      final box = bounds[items[j]];
      minX = math.min(minX, box.minimum.x);
      minY = math.min(minY, box.minimum.y);
      minZ = math.min(minZ, box.minimum.z);
      maxX = math.max(maxX, box.maximum.x);
      maxY = math.max(maxY, box.maximum.y);
      maxZ = math.max(maxZ, box.maximum.z);
    }
    return Bounds3(Vec3(minX, minY, minZ), Vec3(maxX, maxY, maxZ));
  }

  _BoundsBvh refit(List<Bounds3> bounds) {
    _BvhNode update(_BvhNode node) {
      if (node.items case final items?) {
        final box = _enclose(bounds, items, 0, items.length);
        if (box.minimum == node.bounds.minimum &&
            box.maximum == node.bounds.maximum) {
          return node;
        }
        return _BvhNode(box, items);
      }
      final a = update(node.left!), b = update(node.right!);
      if (identical(a, node.left) && identical(b, node.right)) return node;
      return _BvhNode(a.bounds.union(b.bounds), null, a, b);
    }

    return _BoundsBvh._(root == null ? null : update(root!));
  }

  void visit(
    Ray ray,
    double Function() limit,
    void Function(int) hit,
    _RaycastCounters stats,
  ) {
    double? entry(_BvhNode node) {
      stats.bvhBoundsTests++;
      return ray.intersectBounds(node.bounds);
    }

    void walk(_BvhNode node, double distance) {
      if (distance > limit()) return;
      if (node.items case final items?) {
        for (final i in items) {
          hit(i);
        }
        return;
      }
      final a = node.left!, b = node.right!;
      final da = entry(a), db = entry(b);
      if (da == null) {
        if (db != null) walk(b, db);
      } else if (db == null) {
        walk(a, da);
      } else if (da <= db) {
        walk(a, da);
        walk(b, db);
      } else {
        walk(b, db);
        walk(a, da);
      }
    }

    if (root case final node?) {
      final distance = entry(node);
      if (distance != null) walk(node, distance);
    }
  }
}

final class _BvhNode {
  final Bounds3 bounds;
  final List<int>? items;
  final _BvhNode? left, right;
  _BvhNode(this.bounds, this.items, [this.left, this.right]);
}

final class _GeometryBvh {
  final GeometrySnapshot geometry;
  final DeformationSnapshot? pose;
  final List<double> positions;
  final _BoundsBvh tree;
  _GeometryBvh._(this.geometry, this.pose, this.positions, this.tree);

  static _GeometryBvh update(
    GeometrySnapshot geometry,
    DeformationSnapshot? pose,
    _GeometryBvh? previous,
    _RaycastCounters stats,
  ) {
    if (previous != null &&
        identical(geometry, previous.geometry) &&
        identical(pose, previous.pose)) {
      return previous;
    }
    final compatible =
        previous != null &&
        previous.geometry.logicalId == geometry.logicalId &&
        identical(previous.geometry.indices, geometry.indices);
    if (compatible &&
        identical(geometry.positions, previous.geometry.positions) &&
        _samePose(pose, previous.pose)) {
      return _GeometryBvh._(geometry, pose, previous.positions, previous.tree);
    }
    final positions = pose == null
        ? geometry.positions
        : Float64List.fromList([
            for (var i = 0; i < geometry.layout.vertexCount; i++)
              ...pose.vertexPosition(i).storage,
          ]).asUnmodifiableView();
    final bounds = <Bounds3>[];
    Vec3 vertex(int i) => Vec3.array(positions, i * 3);
    for (var i = 0; i < geometry.indices.length; i += 3) {
      final a = vertex(geometry.indices[i]),
          b = vertex(geometry.indices[i + 1]),
          c = vertex(geometry.indices[i + 2]);
      bounds.add(
        Bounds3(
          Vec3(
            math.min(a.x, math.min(b.x, c.x)),
            math.min(a.y, math.min(b.y, c.y)),
            math.min(a.z, math.min(b.z, c.z)),
          ),
          Vec3(
            math.max(a.x, math.max(b.x, c.x)),
            math.max(a.y, math.max(b.y, c.y)),
            math.max(a.z, math.max(b.z, c.z)),
          ),
        ),
      );
    }
    final _BoundsBvh tree;
    if (compatible) {
      tree = previous.tree.refit(bounds);
      stats.geometryRefits++;
    } else {
      tree = _BoundsBvh(bounds);
      stats.geometryBuilds++;
    }
    return _GeometryBvh._(geometry, pose, positions, tree);
  }

  static bool _samePose(DeformationSnapshot? a, DeformationSnapshot? b) {
    if (identical(a, b)) return true;
    if (a == null ||
        b == null ||
        a.weights.length != b.weights.length ||
        a.matrices.length != b.matrices.length ||
        !identical(a.geometry.joints, b.geometry.joints) ||
        !identical(a.geometry.weights, b.geometry.weights)) {
      return false;
    }
    for (var i = 0; i < a.weights.length; i++) {
      if (a.weights[i] != b.weights[i]) return false;
    }
    for (var i = 0; i < a.matrices.length; i++) {
      if (a.matrices[i] != b.matrices[i]) return false;
    }
    return true;
  }
}

final class _SceneBvh {
  final int revision;
  final LayerMask layers;
  final List<_PickMesh> meshes;
  final _BoundsBvh? tree;
  _SceneBvh(this.revision, this.layers, this.meshes, this.tree);
}

final class _RaycastCounters {
  int geometryBuilds = 0,
      geometryRefits = 0,
      sceneBuilds = 0,
      sceneRefits = 0,
      modelMatrixInversions = 0;
  int meshTests = 0, bvhBoundsTests = 0, triangleTests = 0;
  _RaycastCounters();
  _RaycastCounters.from(RaycastStatistics captured) {
    geometryBuilds = captured.geometryBuilds;
    geometryRefits = captured.geometryRefits;
    sceneBuilds = captured.sceneBuilds;
    sceneRefits = captured.sceneRefits;
    modelMatrixInversions = captured.modelMatrixInversions;
  }
  RaycastStatistics freeze() => RaycastStatistics._(
    geometryBuilds,
    geometryRefits,
    sceneBuilds,
    sceneRefits,
    modelMatrixInversions,
    meshTests,
    bvhBoundsTests,
    triangleTests,
  );
}
