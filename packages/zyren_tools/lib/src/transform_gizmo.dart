part of '../zyren_tools.dart';

enum GizmoMode { translate, rotate, scale }

enum GizmoAxis {
  x(Vec3(1, 0, 0), 0xf06b64),
  y(Vec3(0, 1, 0), 0x68d391),
  z(Vec3(0, 0, 1), 0x78aaff);

  final Vec3 direction;
  final int color;
  const GizmoAxis(this.direction, this.color);
}

/// Native mesh handles for local-axis transforms. Register before camera controls
/// and pause those controls in [onDragChanged] while a gesture owns the pointer.
class TransformGizmoPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.transform-gizmo';
  @override
  Set<String> get dependencies => const {'zyren.tools'};

  /// Handle radius in the selected object's parent units, before its own scale.
  final double size;
  final double translationSnap, rotationSnap, scaleSnap;
  final void Function(bool dragging)? onDragChanged;
  bool snapEnabled = false;
  bool _enabled = true;
  GizmoMode _mode = GizmoMode.translate;
  final _root = Group(name: 'Transform gizmo');
  final _groups = <GizmoMode, Group>{};
  final _handles = <Mesh, GizmoAxis>{};
  final _materials = <GizmoAxis, UnlitMaterial>{};
  final _activeMaterial = UnlitMaterial(color: Color3.hex(0xffdf85));
  final _raycaster = Raycaster();
  PluginContext? _context;
  SceneToolsPlugin? _tools;
  _GizmoDrag? _drag;
  Quat? _shownRotation;
  bool _syncing = false;

  TransformGizmoPlugin({
    this.size = 1.5,
    this.translationSnap = .25,
    this.rotationSnap = math.pi / 12,
    this.scaleSnap = .1,
    this.onDragChanged,
  }) {
    if ([
      size,
      translationSnap,
      rotationSnap,
      scaleSnap,
    ].any((value) => !value.isFinite || value <= 0)) {
      throw ArgumentError(
        'Gizmo size and snap increments must be finite and positive.',
      );
    }
    _buildHandles();
  }

  bool get isDragging => _drag != null;
  GizmoAxis? get activeAxis => _drag?.axis;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    cancel();
    _enabled = value;
    _sync();
  }

  GizmoMode get mode => _mode;
  set mode(GizmoMode value) {
    if (_mode == value) return;
    cancel();
    _mode = value;
    _sync();
  }

  /// Lets a host omit editor handles from an assembly list or export.
  bool owns(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (identical(node, _root)) return true;
    }
    return false;
  }

  @override
  void attach(PluginContext context) {
    _context = context;
    _tools = context.service(sceneTools);
    context.scope.keep(_tools!.excludeFromPicking(_root));
    context.scope.listen(_tools!.changes, (_) => _sync());
    context.scope.listen(context.scene.changes, (_) => _sync());
    final input = context.input;
    if (input is ViewportInputSource) {
      context.scope.keep(input.registerGesture(SceneGesture.pointerDrag));
      context.scope.listen(
        input.events,
        (event) => handlePointer(event, input.viewport),
      );
    }
    if (input is KeyboardInputSource) {
      context.scope.keep(input.registerKeys({SceneKey.escape}));
      context.scope.listen(input.keyEvents, (event) {
        if (event.key == SceneKey.escape && event.phase == SceneKeyPhase.down) {
          cancel();
        }
      });
    }
    _sync();
  }

  bool _visible(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (!node.visible) return false;
    }
    return _tools!._contains(object);
  }

  void _sync() {
    final context = _context;
    if (context == null || _syncing) return;
    _syncing = true;
    try {
      final selected = _tools!.selected;
      final visible =
          _enabled && selected != null && _visible(selected) && !owns(selected);
      if (_drag != null &&
          (!visible ||
              !identical(selected, _drag!.session.object) ||
              !_drag!.session._ownsPose ||
              !identical(context.camera, _drag!.camera) ||
              context.camera.revision != _drag!.cameraRevision)) {
        cancel();
      }
      context.scene.batch(() {
        if (visible) {
          selected.parent!.add(_root);
          _root.position = selected.position;
          if (_shownRotation != selected.quaternion) {
            _root.quaternion = selected.quaternion;
            _shownRotation = selected.quaternion;
          }
        }
        _root.visible = visible;
        for (final entry in _groups.entries) {
          entry.value.visible = entry.key == _mode;
        }
        for (final entry in _handles.entries) {
          final material = entry.value == activeAxis
              ? _activeMaterial
              : _materials[entry.value]!;
          if (!identical(entry.key.material, material)) {
            entry.key.material = material;
          }
        }
      });
    } finally {
      _syncing = false;
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) => _sync();

  CameraRay _ray(ViewportPoint point, ViewportMetrics viewport) {
    final ndc = point.toNdc(
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
    );
    return _context!.camera.rayFromNdc(ndc.x, ndc.y, viewport.aspect);
  }

  /// Returns only a visible handle at the frontmost clipped surface.
  GizmoAxis? hitTest(ViewportPoint point, ViewportMetrics viewport) {
    if (_context == null ||
        !viewport.isUsable ||
        !point.x.isFinite ||
        !point.y.isFinite ||
        point.x < 0 ||
        point.y < 0 ||
        point.x > viewport.width ||
        point.y > viewport.height) {
      return null;
    }
    _sync();
    if (!_root.visible) return null;
    for (final hit in _raycaster.intersectScene(
      _context!.scene,
      _ray(point, viewport),
    )) {
      final depth = _context!.camera.projectPoint(hit.point, viewport.aspect).z;
      if (depth < 0 || depth > 1) continue;
      return _handles[hit.object];
    }
    return null;
  }

  /// Headless hosts can route logical pointer coordinates here directly.
  void handlePointer(ScenePointerEvent event, ViewportMetrics viewport) {
    if (_context == null) return;
    _sync();
    final drag = _drag;
    if (drag != null) {
      _tools!._suppressTap = true;
      if (drag.pointer != event.pointer) return;
      if (event.phase == ScenePointerPhase.cancel ||
          !viewport.isUsable ||
          viewport.width != drag.viewport.width ||
          viewport.height != drag.viewport.height) {
        cancel();
        return;
      }
      if (event.phase == ScenePointerPhase.move ||
          event.phase == ScenePointerPhase.up) {
        if (!event.point.x.isFinite || !event.point.y.isFinite) {
          cancel();
          return;
        }
        final ray = _localRay(_ray(event.point, viewport), drag.inverse);
        final snap =
            snapEnabled || event.modifiers.contains(SceneModifier.shift);
        final amount = _amount(ray, drag.axis, drag.mode);
        if (amount != null) {
          var delta = amount - drag.start;
          switch (drag.mode) {
            case GizmoMode.translate:
              if (snap) delta = _snap(delta, translationSnap);
              drag.session.update(
                position:
                    drag.pose.position +
                    drag.pose.rotation.rotate(drag.axis.direction) * delta,
              );
            case GizmoMode.rotate:
              // Accumulate wrapped increments so a drag can cross the +/- pi seam.
              var step = amount - drag.previous;
              if (step > math.pi) step -= math.pi * 2;
              if (step < -math.pi) step += math.pi * 2;
              drag.angle += step;
              drag.previous = amount;
              final angle = snap ? _snap(drag.angle, rotationSnap) : drag.angle;
              drag.session.update(
                rotation:
                    drag.pose.rotation *
                    Quat.axisAngle(drag.axis.direction, angle),
              );
            case GizmoMode.scale:
              var factor = 1 + delta / size;
              if (snap) factor = _snap(factor, scaleSnap);
              factor = math.max(.05, factor);
              final scale = drag.pose.scale;
              drag.session.update(
                scale: switch (drag.axis) {
                  GizmoAxis.x => Vec3(scale.x * factor, scale.y, scale.z),
                  GizmoAxis.y => Vec3(scale.x, scale.y * factor, scale.z),
                  GizmoAxis.z => Vec3(scale.x, scale.y, scale.z * factor),
                },
              );
          }
        }
        if (event.phase == ScenePointerPhase.up) {
          drag.session.commit();
          _end();
        }
        _sync();
      }
      return;
    }
    if (event.phase != ScenePointerPhase.down ||
        (event.kind != ScenePointerKind.touch && event.buttons != 1)) {
      return;
    }
    final axis = hitTest(event.point, viewport);
    if (axis == null) return;
    final selected = _tools!.selected!;
    final inverse = _world(_root).inverted();
    final amount = _amount(
      _localRay(_ray(event.point, viewport), inverse),
      axis,
      _mode,
    );
    // An axis aimed at the camera has no stable screen-space drag direction.
    if (amount == null || _tools!._session != null) return;
    _tools!._suppressTap = true;
    _drag = _GizmoDrag(
      _tools!.beginTransform(selected),
      axis,
      _mode,
      event.pointer,
      inverse,
      viewport,
      _context!.camera,
      amount,
    );
    onDragChanged?.call(true);
    _sync();
  }

  void cancel() {
    if (_drag == null) return;
    _drag!.session.cancel();
    _end();
    _sync();
  }

  void _end() {
    _drag = null;
    onDragChanged?.call(false);
    _context?.invalidate();
  }

  @override
  void detach(PluginContext context) {
    try {
      cancel();
    } finally {
      _root.parent?.remove(_root);
      _tools = null;
      _context = null;
    }
  }

  void _buildHandles() {
    final shaft = BoxGeometry(
      width: size * .7,
      height: size * .055,
      depth: size * .055,
    );
    final cube = BoxGeometry(
      width: size * .17,
      height: size * .17,
      depth: size * .17,
    );
    final arrow = _cone(size);
    final ring = _ring(size * .85, size * .035);
    for (final axis in GizmoAxis.values) {
      _materials[axis] = UnlitMaterial(color: Color3.hex(axis.color));
    }
    for (final mode in GizmoMode.values) {
      final group = _root.add(Group(name: mode.name));
      _groups[mode] = group;
      for (final axis in GizmoAxis.values) {
        final rotation = switch (axis) {
          GizmoAxis.x => Quat.identity,
          GizmoAxis.y => Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2),
          GizmoAxis.z => Quat.axisAngle(const Vec3(0, 1, 0), -math.pi / 2),
        };
        void add(BufferGeometry geometry, double offset) {
          final mesh = group.add(
            Mesh(
              geometry,
              _materials[axis]!,
              name: '${mode.name} ${axis.name}',
            ),
          );
          mesh.position = axis.direction * offset;
          mesh.quaternion = rotation;
          _handles[mesh] = axis;
        }

        if (mode == GizmoMode.rotate) {
          add(ring, 0);
        } else {
          add(shaft, size * .5);
          add(
            mode == GizmoMode.translate ? arrow : cube,
            mode == GizmoMode.translate ? 0 : size,
          );
        }
      }
    }
    _root.visible = false;
  }
}

final class _GizmoDrag {
  final TransformSession session;
  final GizmoAxis axis;
  final GizmoMode mode;
  final int pointer, cameraRevision;
  final Camera camera;
  final Mat4 inverse;
  final ViewportMetrics viewport;
  final double start;
  final _Pose pose;
  double previous, angle = 0;
  _GizmoDrag(
    this.session,
    this.axis,
    this.mode,
    this.pointer,
    this.inverse,
    this.viewport,
    this.camera,
    this.start,
  ) : cameraRevision = camera.revision,
      pose = _Pose.capture(session.object),
      previous = start;
}

double _snap(double value, double step) =>
    (value / step).roundToDouble() * step;

Mat4 _world(Object3D object) => object.parent == null
    ? object.localMatrix
    : _world(object.parent!) * object.localMatrix;

Vec3 _point(Mat4 matrix, Vec3 point, {double w = 1}) {
  final m = matrix.storage;
  return Vec3(
    m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12] * w,
    m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13] * w,
    m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14] * w,
  );
}

CameraRay _localRay(CameraRay ray, Mat4 inverse) => CameraRay(
  _point(inverse, ray.origin),
  _point(inverse, ray.direction, w: 0),
);

double? _amount(CameraRay ray, GizmoAxis axis, GizmoMode mode) {
  final a = axis.direction, d = ray.direction, o = ray.origin;
  final dot = a.dot(d);
  if (mode != GizmoMode.rotate) {
    final denominator = 1 - dot * dot;
    if (denominator < .0025) return null;
    return (a.dot(o) - dot * d.dot(o)) / denominator;
  }
  if (dot.abs() < .025) return null;
  final t = -a.dot(o) / dot;
  if (t < 0) return null;
  final p = ray.at(t);
  if (p.length2 < 1e-12) return null;
  return switch (axis) {
    GizmoAxis.x => math.atan2(p.z, p.y),
    GizmoAxis.y => math.atan2(p.x, p.z),
    GizmoAxis.z => math.atan2(p.y, p.x),
  };
}

BufferGeometry _cone(double size) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  for (var i = 0; i < 16; i++) {
    final a = i * math.pi / 8, b = (i + 1) * math.pi / 8;
    final points = [
      Vec3(size * 1.12, 0, 0),
      Vec3(size * .82, math.cos(a) * size * .12, math.sin(a) * size * .12),
      Vec3(size * .82, math.cos(b) * size * .12, math.sin(b) * size * .12),
    ];
    final normal = (points[1] - points[0])
        .cross(points[2] - points[0])
        .normalized();
    for (final point in points) {
      indices.add(indices.length);
      positions.addAll(point.storage);
      normals.addAll(normal.storage);
    }
    for (final point in [Vec3(size * .82, 0, 0), points[2], points[1]]) {
      indices.add(indices.length);
      positions.addAll(point.storage);
      normals.addAll(const Vec3(-1, 0, 0).storage);
    }
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
}

BufferGeometry _ring(double radius, double tube) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  const segments = 64, sides = 8;
  for (var i = 0; i < segments; i++) {
    final theta = i * 2 * math.pi / segments;
    for (var j = 0; j < sides; j++) {
      final phi = j * 2 * math.pi / sides;
      final normal = Vec3(
        math.sin(phi),
        math.cos(theta) * math.cos(phi),
        math.sin(theta) * math.cos(phi),
      );
      positions.addAll(
        (Vec3(0, radius * math.cos(theta), radius * math.sin(theta)) +
                normal * tube)
            .storage,
      );
      normals.addAll(normal.storage);
      final a = i * sides + j, b = ((i + 1) % segments) * sides + j;
      final c = ((i + 1) % segments) * sides + (j + 1) % sides;
      final d = i * sides + (j + 1) % sides;
      indices.addAll([a, b, c, a, c, d]);
    }
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
}
