library;

import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';

part 'src/transform_gizmo.dart';
part 'src/scene_section.dart';
part 'src/scene_outline.dart';

const sceneTools = ServiceKey<SceneToolsPlugin>('zyren.tools');

/// World-space anchors measured in the scene's own units.
final class SceneMeasurement {
  final Vec3 start, end;
  final double distance;
  SceneMeasurement(this.start, this.end) : distance = start.distanceTo(end) {
    if (!start.isFinite || !end.isFinite || !distance.isFinite) {
      throw ArgumentError('Measurement anchors must have finite distance.');
    }
  }
}

/// Selection and reversible local transforms for one attached scene.
class SceneToolsPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.tools';
  final int historyLimit;
  final Color3 highlightColor;
  final bool selectOnTap;
  final bool highlightSelection;
  final _changes = StreamController<void>.broadcast();
  final _raycaster = Raycaster();
  final _undo = <_TransformEdit>[], _redo = <_TransformEdit>[];
  final _measurements = <SceneMeasurement>[];
  PluginContext? _context;
  Object3D? _selected;
  TransformSession? _session;
  final _pickExclusions = <Object3D, int>{};
  bool _suppressTap = false;
  MeshMaterial? _original, _highlight;

  SceneToolsPlugin({
    this.historyLimit = 100,
    this.selectOnTap = true,
    this.highlightSelection = true,
    Color3? highlightColor,
  }) : highlightColor = highlightColor ?? Color3.hex(0xf2bd65) {
    if (historyLimit < 1) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
  }

  Stream<void> get changes => _changes.stream;
  Object3D? get selected => _selected;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  List<SceneMeasurement> get measurements => List.unmodifiable(_measurements);
  PluginContext get _attached =>
      _context ?? (throw StateError('Attach scene tools before using them.'));

  @override
  void attach(PluginContext context) {
    _context = context;
    context.provide(sceneTools, this);
    context.scope.listen(context.scene.changes, (_) {
      if (_selected != null && !_contains(_selected!)) select(null);
    });
    final input = context.input;
    if (selectOnTap && input is ViewportInputSource) {
      context.scope.keep(input.registerGesture(SceneGesture.tap));
      context.scope.listen(input.events, (event) {
        if (event.phase == ScenePointerPhase.down) _suppressTap = false;
        if (event.phase == ScenePointerPhase.tap &&
            !_suppressTap &&
            _session == null) {
          select(pick(event.point, input.viewport)?.object);
        }
      });
    }
  }

  bool _contains(Object3D object) {
    final scene = _attached.scene;
    for (Object3D? node = object; node != null; node = node.parent) {
      if (identical(node, scene)) return !identical(object, scene);
    }
    return false;
  }

  void _requireMember(Object3D object) {
    if (!_contains(object)) {
      throw ArgumentError('Object must belong to this scene.');
    }
  }

  /// Returns the closest visible triangle within the active camera's clip range.
  PickResult? pick(ViewportPoint point, ViewportMetrics viewport) {
    final context = _attached;
    if (!viewport.isUsable) {
      throw ArgumentError('Viewport must have a finite size.');
    }
    if (!point.x.isFinite || !point.y.isFinite) {
      throw ArgumentError('Point must be finite.');
    }
    if (point.x < 0 ||
        point.y < 0 ||
        point.x > viewport.width ||
        point.y > viewport.height) {
      return null;
    }
    final ndc = point.toNdc(
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
    );
    final camera = context.camera;
    final ray = camera.rayFromNdc(ndc.x, ndc.y, viewport.aspect);
    for (final hit in _raycaster.intersectScene(context.scene, ray)) {
      if (_excluded(hit.object)) continue;
      final projected = camera.projectPoint(hit.point, viewport.aspect);
      if (projected.z >= 0 && projected.z <= 1) return hit;
    }
    return null;
  }

  bool _excluded(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (_pickExclusions.containsKey(node)) return true;
    }
    return false;
  }

  /// Excludes a helper subtree from surface picking until the lease is released.
  Registration excludeFromPicking(Object3D root) {
    final context = _attached;
    _pickExclusions.update(root, (count) => count + 1, ifAbsent: () => 1);
    return context.scope.keep(
      Registration(() {
        if (!identical(_context, context)) return;
        final count = _pickExclusions[root];
        if (count == null) return;
        if (count == 1) {
          _pickExclusions.remove(root);
        } else {
          _pickExclusions[root] = count - 1;
        }
      }),
    );
  }

  void select(Object3D? object) {
    _attached;
    if (object != null) _requireMember(object);
    if (identical(object, _selected)) return;
    _session?.cancel();
    _restoreHighlight();
    _selected = object;
    if (object is Mesh && highlightSelection) {
      _original = object.material;
      _highlight = switch (object.material) {
        DiffuseMaterial material => material.copyWith(color: highlightColor),
        UnlitMaterial material => material.copyWith(color: highlightColor),
        LineMaterial material => material.copyWith(color: highlightColor),
        PointsMaterial material => material.copyWith(color: highlightColor),
        StandardMaterial material => material.copyWith(color: highlightColor),
        ShaderMaterial material => material.copyWith(color: highlightColor),
      };
      object.material = _highlight!;
    }
    _notify();
  }

  void _restoreHighlight() {
    final object = _selected;
    if (object is Mesh && identical(object.material, _highlight)) {
      object.material = _original!;
    }
    _original = _highlight = null;
  }

  /// Replaces local components. A grid snaps only the supplied position.
  void transform(
    Object3D object, {
    Vec3? position,
    Quat? rotation,
    Vec3? scale,
    double? grid,
  }) {
    _requireIdle();
    _requireMember(object);
    final next = _nextPose(object, position, rotation, scale, grid);
    final before = _Pose.capture(object);
    if (before == next) return;
    _attached.scene.batch(() => next.apply(object));
    _record(object, before, _Pose.capture(object));
  }

  _Pose _nextPose(
    Object3D object,
    Vec3? position,
    Quat? rotation,
    Vec3? scale,
    double? grid,
  ) {
    if (grid != null && (!grid.isFinite || grid <= 0)) {
      throw ArgumentError('Grid spacing must be finite and positive.');
    }
    var nextPosition = position ?? object.position;
    if (position != null && grid != null) {
      if (!position.isFinite || !(position / grid).isFinite) {
        throw ArgumentError('Position cannot be snapped.');
      }
      nextPosition = Vec3(
        (position.x / grid).roundToDouble() * grid,
        (position.y / grid).roundToDouble() * grid,
        (position.z / grid).roundToDouble() * grid,
      );
    }
    return _Pose(
      nextPosition,
      rotation ?? object.quaternion,
      scale ?? object.scale,
    );
  }

  void _record(Object3D object, _Pose before, _Pose after) {
    if (before == after) return;
    _undo.add(_TransformEdit(object, object.parent, before, after));
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
    _notify();
  }

  /// Previews a gesture and records a single edit when you commit it.
  /// Only one session can own transforms at a time.
  TransformSession beginTransform(Object3D object) {
    _requireIdle();
    _requireMember(object);
    return _session = TransformSession._(this, object);
  }

  void _requireIdle() {
    _attached;
    if (_session != null) {
      throw StateError('Finish the active transform first.');
    }
  }

  bool undo() => _move(_undo, _redo, undo: true);
  bool redo() => _move(_redo, _undo, undo: false);
  bool _move(
    List<_TransformEdit> source,
    List<_TransformEdit> target, {
    required bool undo,
  }) {
    _requireIdle();
    if (source.isEmpty) return false;
    final edit = source.last;
    final expected = undo ? edit.after : edit.before;
    if (!_contains(edit.object) ||
        !identical(edit.parent, edit.object.parent) ||
        _Pose.capture(edit.object) != expected) {
      throw StateError(
        'The object changed outside this history. Clear history before editing it again.',
      );
    }
    _attached.scene.batch(
      () => (undo ? edit.before : edit.after).apply(edit.object),
    );
    source.removeLast();
    target.add(edit);
    _notify();
    return true;
  }

  void clearHistory() {
    _session?.cancel();
    _undo.clear();
    _redo.clear();
    _notify();
  }

  SceneMeasurement measure(Vec3 start, Vec3 end) {
    _attached;
    final measurement = SceneMeasurement(start, end);
    _measurements.add(measurement);
    _notify();
    return measurement;
  }

  void clearMeasurements() {
    _measurements.clear();
    _notify();
  }

  void _notify() {
    _changes.add(null);
    _context?.invalidate();
  }

  @override
  void detach(PluginContext context) {
    _session?.cancel();
    _restoreHighlight();
    _selected = null;
    _undo.clear();
    _redo.clear();
    _measurements.clear();
    _pickExclusions.clear();
    _suppressTap = false;
    _context = null;
    _changes.add(null);
  }
}

/// A local transform gesture. Failed ownership checks leave external edits intact.
final class TransformSession {
  final SceneToolsPlugin _tools;
  final Object3D object;
  final _Pose _before;
  late _Pose _expected = _before;
  final List<(Object3D, Mat4)> _ancestors;
  bool _active = true;
  TransformSession._(this._tools, this.object)
    : _before = _Pose.capture(object),
      _ancestors = _parents(object);

  bool get isActive => _active;
  bool get _ownsPose {
    if (!_active ||
        !_tools._contains(object) ||
        _Pose.capture(object) != _expected) {
      return false;
    }
    final parents = _parents(object);
    return parents.length == _ancestors.length &&
        Iterable<int>.generate(parents.length).every(
          (i) =>
              identical(parents[i].$1, _ancestors[i].$1) &&
              parents[i].$2 == _ancestors[i].$2,
        );
  }

  static List<(Object3D, Mat4)> _parents(Object3D object) => [
    for (
      Object3D? parent = object.parent;
      parent != null;
      parent = parent.parent
    )
      (parent, parent.localMatrix),
  ];

  void _check() {
    if (!_active) throw StateError('The transform session has ended.');
    if (!_ownsPose) {
      _finish();
      throw StateError(
        'The object or its ancestors changed outside this gesture.',
      );
    }
  }

  void update({Vec3? position, Quat? rotation, Vec3? scale, double? grid}) {
    _check();
    final next = _tools._nextPose(object, position, rotation, scale, grid);
    _tools._attached.scene.batch(() => next.apply(object));
    _expected = _Pose.capture(object);
    _tools._notify();
  }

  void commit() {
    _check();
    _finish();
    _tools._record(object, _before, _expected);
  }

  /// Returns false if another writer took ownership. Nothing is overwritten.
  bool cancel() {
    if (!_active) return false;
    final restore = _ownsPose;
    if (restore) _tools._attached.scene.batch(() => _before.apply(object));
    _finish();
    _tools._notify();
    return restore;
  }

  void _finish() {
    _active = false;
    _tools._session = null;
  }
}

final class _Pose {
  final Vec3 position, scale;
  final Quat rotation;
  _Pose(this.position, Quat rotation, this.scale)
    : rotation = rotation.normalized() {
    if (!position.isFinite ||
        !scale.isFinite ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0) {
      throw ArgumentError('Transforms must be finite with nonzero scale.');
    }
  }
  _Pose.capture(Object3D object)
    : position = object.position,
      rotation = object.quaternion,
      scale = object.scale;
  void apply(Object3D object) {
    object.position = position;
    object.quaternion = rotation;
    object.scale = scale;
  }

  @override
  bool operator ==(Object other) =>
      other is _Pose &&
      position == other.position &&
      rotation == other.rotation &&
      scale == other.scale;
  @override
  int get hashCode => Object.hash(position, rotation, scale);
}

final class _TransformEdit {
  final Object3D object;
  final Object3D? parent;
  final _Pose before, after;
  _TransformEdit(this.object, this.parent, this.before, this.after);
}
