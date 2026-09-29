part of 'scene.dart';

/// Shared triangle geometry with independent local transforms and RGB tints.
/// Capacity is fixed; [count] selects the visible prefix of that storage.
final class InstancedMesh extends Mesh {
  static int _nextLogicalId = 1;
  final int _logicalId = _nextLogicalId++;
  final int capacity;
  int _count, _instanceRevision = 0;
  final List<Mat4> _transforms;
  final List<Color3> _colors;
  final List<_InstanceChange> _history = [];
  InstanceSnapshot? _snapshot;
  InstancedMesh(
    super.geometry,
    super.material, {
    required int count,
    super.name,
    super.renderOrder,
  }) : capacity = _capacity(count),
       _count = count,
       _transforms = List.filled(_capacity(count), Mat4.identity()),
       _colors = List.filled(_capacity(count), const Color3(1, 1, 1)) {
    if (geometry.topology != GeometryTopology.triangles) {
      throw ArgumentError('InstancedMesh requires triangle geometry.');
    }
  }
  static int _capacity(int count) =>
      RangeError.checkValueInInterval(count, 0, 100000, 'count');
  int get count => _count;
  set count(int value) {
    RangeError.checkValueInInterval(value, 0, capacity, 'count');
    if (_count == value) return;
    _count = value;
    _changed();
  }

  Mat4 getTransform(int index) =>
      _transforms[RangeError.checkValidIndex(index, _transforms, 'index')];
  void setTransform(int index, Mat4 transform) =>
      setTransforms(index, [transform]);

  /// Validates the complete range before publishing it. Matrices are immutable.
  void setTransforms(int first, List<Mat4> transforms) {
    RangeError.checkValueInInterval(first, 0, capacity, 'first');
    if (transforms.length > capacity - first) {
      throw RangeError('Instance transform range exceeds capacity.');
    }
    var changed = false;
    for (var i = 0; i < transforms.length; i++) {
      final m = transforms[i].storage, matrix = transforms[i].toVectorMath();
      final determinant = matrix.determinant();
      if (m[3] != 0 ||
          m[7] != 0 ||
          m[11] != 0 ||
          m[15] != 1 ||
          !determinant.isFinite ||
          determinant == 0) {
        throw ArgumentError(
          'Instance transforms must be affine and invertible.',
        );
      }
      changed |= _transforms[first + i] != transforms[i];
    }
    if (!changed) return;
    _transforms.setRange(first, first + transforms.length, transforms);
    _publishRange(first, transforms.length);
  }

  Color3 getColor(int index) =>
      _colors[RangeError.checkValidIndex(index, _colors, 'index')];

  /// Multiplies the material and vertex RGB. White preserves their colors.
  void setColor(int index, Color3 color) => setColors(index, [color]);

  /// Validates every linear RGB channel before publishing the range.
  void setColors(int first, List<Color3> colors) {
    RangeError.checkValueInInterval(first, 0, capacity, 'first');
    if (colors.length > capacity - first) {
      throw RangeError('Instance color range exceeds capacity.');
    }
    var changed = false;
    for (var i = 0; i < colors.length; i++) {
      colors[i].toList();
      changed |= _colors[first + i] != colors[i];
    }
    if (!changed) return;
    _colors.setRange(first, first + colors.length, colors);
    _publishRange(first, colors.length);
  }

  void _publishRange(int first, int count) {
    _instanceRevision++;
    if (_history.length == 64) _history.removeAt(0);
    _history.add(
      _InstanceChange(_instanceRevision, InstanceRange(first, count)),
    );
    _snapshot = null;
    _changed();
  }

  InstanceSnapshot captureInstances() => _snapshot ??= InstanceSnapshot._(
    _logicalId,
    _instanceRevision,
    _transforms,
    _colors,
    _history,
  );
  @override
  Bounds3 get bounds => captureInstances().boundsFor(
    geometry.capture(),
    count: count,
    localBounds: captureDeformation()?.bounds,
  );
}

final class InstanceRange {
  final int first, count;
  const InstanceRange(this.first, this.count);
}

final class _InstanceChange {
  final int revision;
  final InstanceRange range;
  const _InstanceChange(this.revision, this.range);
}

/// Immutable data for a captured instance-buffer version. IDs identify storage,
/// while a mesh's count and parent transform remain separate draw properties.
final class InstanceSnapshot {
  static int _nextId = 1;
  final int id = _nextId++;
  final int logicalId, revision;
  final List<Mat4> transforms;
  final List<Color3> colors;
  final List<_InstanceChange> _history;
  GeometrySnapshot? _boundsGeometry;
  int _boundsCount = -1;
  Bounds3? _bounds;
  InstanceSnapshot._(
    this.logicalId,
    this.revision,
    List<Mat4> transforms,
    List<Color3> colors,
    List<_InstanceChange> history,
  ) : transforms = List.unmodifiable(transforms),
      colors = List.unmodifiable(colors),
      _history = List.unmodifiable(history);
  int get capacity => transforms.length;
  int get gpuByteLength => capacity * 128;
  List<InstanceRange>? changesSince(InstanceSnapshot base) {
    if (logicalId != base.logicalId ||
        capacity != base.capacity ||
        base.revision > revision) {
      return null;
    }
    if (base.revision == revision) return const [];
    if (_history.isEmpty || _history.first.revision > base.revision + 1) {
      return null;
    }
    final ranges = [
      for (final change in _history)
        if (change.revision > base.revision) change.range,
    ]..sort((a, b) => a.first.compareTo(b.first));
    final merged = <InstanceRange>[];
    for (final range in ranges) {
      if (merged.isNotEmpty &&
          range.first <= merged.last.first + merged.last.count) {
        final previous = merged.removeLast();
        merged.add(
          InstanceRange(
            previous.first,
            math.max(
                  previous.first + previous.count,
                  range.first + range.count,
                ) -
                previous.first,
          ),
        );
      } else {
        merged.add(range);
      }
    }
    return List.unmodifiable(merged);
  }

  Bounds3? _boundsLocal;
  Bounds3 boundsFor(
    GeometrySnapshot geometry, {
    required int count,
    Bounds3? localBounds,
  }) {
    RangeError.checkValueInInterval(count, 0, capacity, 'count');
    if (identical(_boundsGeometry, geometry) &&
        _boundsCount == count &&
        identical(_boundsLocal, localBounds)) {
      return _bounds!;
    }
    final local =
        localBounds ??
        Bounds3(geometry.bounds.minimum, geometry.bounds.maximum);
    _boundsLocal = localBounds;
    var result = const Bounds3.empty();
    for (var i = 0; i < count; i++) {
      result = result.union(local.transformed(transforms[i]));
    }
    _boundsGeometry = geometry;
    _boundsCount = count;
    return _bounds = result;
  }
}
