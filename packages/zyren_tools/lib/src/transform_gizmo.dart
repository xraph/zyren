part of '../zyren_tools.dart';

enum GizmoMode { translate, rotate, scale }

enum GizmoSpace { local, world }

sealed class GizmoHandle {
  String get label;
  int get color;
}

enum GizmoAxis implements GizmoHandle {
  x(Vec3(1, 0, 0), 0xf06b64),
  y(Vec3(0, 1, 0), 0x68d391),
  z(Vec3(0, 0, 1), 0x78aaff);

  final Vec3 direction;
  @override
  final int color;
  const GizmoAxis(this.direction, this.color);
  @override
  String get label => name.toUpperCase();
}

enum GizmoPlane implements GizmoHandle {
  xy(GizmoAxis.x, GizmoAxis.y, GizmoAxis.z),
  xz(GizmoAxis.x, GizmoAxis.z, GizmoAxis.y),
  yz(GizmoAxis.y, GizmoAxis.z, GizmoAxis.x);

  final GizmoAxis first, second, perpendicular;
  const GizmoPlane(this.first, this.second, this.perpendicular);
  @override
  int get color => perpendicular.color;
  @override
  String get label => name.toUpperCase();
}

/// Native mesh handles for local and world transforms. Register before camera controls
/// and pause those controls in [onDragChanged] while a gesture owns the pointer.
class TransformGizmoPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.transform-gizmo';
  @override
  Set<String> get dependencies => const {'zyren.tools'};

  /// Radius in parent units for local axes, or world units for world axes.
  final double size;

  /// Draw and pick handles through scene occluders. Defaults to depth testing.
  bool _alwaysVisible;
  bool get alwaysVisible => _alwaysVisible;
  set alwaysVisible(bool value) {
    if (_alwaysVisible == value) return;
    cancel();
    _alwaysVisible = value;
    for (final handle in _materials.keys.toList()) {
      _materials[handle] = _handleMaterial(handle.color);
    }
    _activeMaterial = _handleMaterial(0xffdf85);
    for (final mesh in _handles.keys) {
      mesh.renderOrder = value ? 0x7fffffff : 0;
    }
    _sync();
    _context?.invalidate();
  }

  /// Optional nominal radius in logical pixels, capped at a third of the shorter
  /// viewport edge. Axes still foreshorten in depth. Omit for scene-unit [size].
  final double? screenSize;
  final double translationSnap, rotationSnap, scaleSnap;
  final void Function(bool dragging)? onDragChanged;
  bool snapEnabled = false;
  bool _enabled = true;
  GizmoMode _mode = GizmoMode.translate;
  GizmoSpace _space = GizmoSpace.local;
  final _root = Group(name: 'Transform gizmo')
    ..clippingEnabled = false
    ..outlineEnabled = false;
  final _frame = Group(name: 'Handle frame');
  final _visuals = Group(name: 'Handle visuals');
  ViewportMetrics? _viewport;
  Mat4? _compensatedParent;
  final _groups = <GizmoMode, Group>{};
  final _handles = <Mesh, GizmoHandle>{};
  final _materials = <GizmoHandle, UnlitMaterial>{};
  late UnlitMaterial _activeMaterial;
  final _raycaster = Raycaster();
  PluginContext? _context;
  SceneToolsPlugin? _tools;
  _GizmoDrag? _drag;
  Quat? _shownRotation;
  bool _syncing = false;

  TransformGizmoPlugin({
    this.size = 1.5,
    bool alwaysVisible = false,
    this.screenSize,
    this.translationSnap = .25,
    this.rotationSnap = math.pi / 12,
    this.scaleSnap = .1,
    this.onDragChanged,
  }) : _alwaysVisible = alwaysVisible {
    if ([
          size,
          translationSnap,
          rotationSnap,
          scaleSnap,
        ].any((value) => !value.isFinite || value <= 0) ||
        (screenSize != null && (!screenSize!.isFinite || screenSize! <= 0))) {
      throw ArgumentError(
        'Gizmo size and snap increments must be finite and positive.',
      );
    }
    _activeMaterial = _handleMaterial(0xffdf85);
    _buildHandles();
  }

  bool get isDragging => _drag != null;
  GizmoHandle? get activeHandle => _drag?.handle;
  GizmoAxis? get activeAxis =>
      activeHandle is GizmoAxis ? activeHandle as GizmoAxis : null;
  GizmoPlane? get activePlane =>
      activeHandle is GizmoPlane ? activeHandle as GizmoPlane : null;
  GizmoSpace get space => _space;
  set space(GizmoSpace value) {
    if (_space == value) return;
    cancel();
    _space = value;
    _sync();
  }

  /// Scale edits always use the object's local axes.
  GizmoSpace get effectiveSpace =>
      _mode == GizmoMode.scale ? GizmoSpace.local : _space;

  /// World rotation cannot introduce shear into a local TRS pose.
  String? get unavailableReason {
    final selected = _tools?.selected;
    if (selected != null &&
        selected.parent != null &&
        _mode == GizmoMode.rotate &&
        effectiveSpace == GizmoSpace.world &&
        !_similarity(_world(selected.parent!))) {
      return 'World rotation requires uniform parent scale. Choose Local.';
    }
    return null;
  }

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
      context.scope.keep(
        InputRouter.forSource(input).register(
          id: id,
          priority: InputPriority.tools,
          claims: (event) =>
              event.phase == ScenePointerPhase.down &&
              hitTestHandle(event.point, input.viewport) != null,
          onEvent: (event) => handlePointer(event, input.viewport),
        ),
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

  /// Supplies logical dimensions for hosts without [ViewportInputSource].
  /// Call before rendering and after resizing. Hit tests also update this value.
  void updateViewport(ViewportMetrics viewport) {
    _viewport = viewport;
    _sync(viewport);
  }

  void _sync([ViewportMetrics? viewport]) {
    final context = _context;
    if (context == null || _syncing) return;
    _syncing = true;
    try {
      final input = context.input;
      viewport ??= input is ViewportInputSource ? input.viewport : _viewport;
      final selected = _tools!.selected;
      final available =
          _enabled &&
          selected != null &&
          _visible(selected) &&
          !owns(selected) &&
          unavailableReason == null;
      var scale = available ? _visualScale(selected, viewport) : null;
      var visible = available && scale != null;
      if (_drag != null &&
          (!visible ||
              !identical(selected, _drag!.session.object) ||
              !_drag!.session._ownsPose ||
              !identical(context.camera, _drag!.camera) ||
              context.camera.revision != _drag!.cameraRevision ||
              (viewport != null &&
                  (!viewport.isUsable ||
                      viewport.width != _drag!.viewport.width ||
                      viewport.height != _drag!.viewport.height)))) {
        cancel();
        scale = available ? _visualScale(selected, viewport) : null;
        visible = available && scale != null;
      }
      context.scene.batch(() {
        if (visible) {
          selected!.parent!.add(_root);
          _placeFrame(selected);
          final factor = _drag == null ? scale! : _drag!.radius / size;
          _visuals.scale = Vec3(factor, factor, factor);
        }
        _root.visible = visible;
        for (final entry in _groups.entries) {
          entry.value.visible = entry.key == _mode;
        }
        for (final entry in _handles.entries) {
          final material = entry.value == activeHandle
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

  double? _visualScale(Object3D selected, ViewportMetrics? viewport) {
    if (screenSize == null) return 1;
    if (viewport == null || !viewport.isUsable) return null;
    final parent = _world(selected.parent!);
    final pivot = _point(parent, selected.position);
    final camera = _context!.camera;
    try {
      final projected = camera.projectPoint(pivot, viewport.aspect);
      if (projected.z < 0 || projected.z > 1) return null;
      final pixels = math.min(
        screenSize!,
        math.min(viewport.width, viewport.height) / 3,
      );
      final offset = camera.unprojectPoint(
        Vec3(
          projected.x,
          projected.y + 2 * pixels / viewport.height,
          projected.z,
        ),
        viewport.aspect,
      );
      final stretch = effectiveSpace == GizmoSpace.world
          ? 1.0
          : GizmoAxis.values
                .map(
                  (axis) => _point(
                    parent,
                    selected.quaternion.rotate(axis.direction),
                    w: 0,
                  ).length,
                )
                .reduce(math.max);
      final scale = pivot.distanceTo(offset) / (size * stretch);
      return scale.isFinite && scale > 0 ? scale : null;
    } on ArgumentError {
      // A pivot at the eye plane cannot be projected to a finite screen span.
      return null;
    }
  }

  void _placeFrame(Object3D selected) {
    final world = effectiveSpace == GizmoSpace.world;
    final rotation = world ? Quat.identity : selected.quaternion;
    _root.position = world ? Vec3.zero : selected.position;
    if (_shownRotation != rotation) {
      _root.quaternion = rotation;
      _shownRotation = rotation;
    }
    if (world) {
      final parentMatrix = _world(selected.parent!);
      if (_compensatedParent != parentMatrix) {
        _frame.parent?.remove(_frame);
        for (final child in _root.children) {
          _root.remove(child);
        }
        var node = _root;
        // Keep inverse scale, rotation and translation separate. Their product
        // cancels even a sheared ancestor chain without decomposing its matrix.
        for (
          Object3D? parent = selected.parent;
          parent != null;
          parent = parent.parent
        ) {
          final s = parent.scale, q = parent.quaternion;
          node = node.add(Group()..scale = Vec3(1 / s.x, 1 / s.y, 1 / s.z));
          node = node.add(Group()..quaternion = Quat(-q.x, -q.y, -q.z, q.w));
          node = node.add(Group()..position = -parent.position);
        }
        node.add(_frame);
        _compensatedParent = parentMatrix;
      }
      _frame.position = _point(_world(selected), Vec3.zero);
    } else {
      if (_compensatedParent != null) {
        _frame.parent?.remove(_frame);
        for (final child in _root.children) {
          _root.remove(child);
        }
        _compensatedParent = null;
      }
      _root.add(_frame);
      _frame.position = Vec3.zero;
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

  /// Axis-only compatibility query. Use [hitTestHandle] to include plane pads.
  GizmoAxis? hitTest(ViewportPoint point, ViewportMetrics viewport) {
    final handle = hitTestHandle(point, viewport);
    return handle is GizmoAxis ? handle : null;
  }

  /// Returns a handle at the frontmost surface, or through occluders when enabled.
  GizmoHandle? hitTestHandle(ViewportPoint point, ViewportMetrics viewport) {
    updateViewport(viewport);
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
    if (!_root.visible) return null;
    for (final hit in _raycaster.intersectScene(
      _context!.scene,
      _ray(point, viewport),
    )) {
      final depth = _context!.camera.projectPoint(hit.point, viewport.aspect).z;
      if (depth < 0 || depth > 1) continue;
      final handle = _handles[hit.object];
      if (alwaysVisible && handle == null) continue;
      return handle;
    }
    return null;
  }

  /// Headless hosts can route logical pointer coordinates here directly.
  void handlePointer(ScenePointerEvent event, ViewportMetrics viewport) {
    if (_context == null) return;
    updateViewport(viewport);
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
        final amount = _sample(ray, drag.handle, drag.mode);
        if (amount != null) {
          switch (drag.mode) {
            case GizmoMode.translate:
              final delta = amount - drag.start;
              Vec3 movement;
              if (drag.handle case final GizmoPlane plane) {
                double component(GizmoAxis axis) => snap
                    ? _snap(delta.dot(axis.direction), translationSnap)
                    : delta.dot(axis.direction);
                movement =
                    plane.first.direction * component(plane.first) +
                    plane.second.direction * component(plane.second);
              } else {
                movement =
                    (drag.handle as GizmoAxis).direction *
                    (snap ? _snap(delta.x, translationSnap) : delta.x);
              }
              drag.session.update(
                position:
                    drag.pose.position +
                    (drag.space == GizmoSpace.world
                        ? _point(drag.parentInverse, movement, w: 0)
                        : drag.pose.rotation.rotate(movement)),
              );
            case GizmoMode.rotate:
              // Accumulate wrapped increments so a drag can cross the +/- pi seam.
              var step = amount.x - drag.previous;
              if (step > math.pi) step -= math.pi * 2;
              if (step < -math.pi) step += math.pi * 2;
              drag.angle += step;
              drag.previous = amount.x;
              final angle = snap ? _snap(drag.angle, rotationSnap) : drag.angle;
              final axis = (drag.handle as GizmoAxis).direction;
              drag.session.update(
                rotation: drag.space == GizmoSpace.world
                    ? Quat.axisAngle(
                            _point(drag.parentInverse, axis, w: 0),
                            angle * drag.handedness,
                          ) *
                          drag.pose.rotation
                    : drag.pose.rotation * Quat.axisAngle(axis, angle),
              );
            case GizmoMode.scale:
              var factor = 1 + (amount.x - drag.start.x) / drag.radius;
              if (snap) factor = _snap(factor, scaleSnap);
              factor = math.max(.05, factor);
              final scale = drag.pose.scale;
              drag.session.update(
                scale: switch (drag.handle as GizmoAxis) {
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
    final handle = hitTestHandle(event.point, viewport);
    if (handle == null) return;
    final selected = _tools!.selected!;
    final inverse = _world(_frame).inverted();
    final amount = _sample(
      _localRay(_ray(event.point, viewport), inverse),
      handle,
      _mode,
    );
    // End-on axes and edge-on planes have no stable screen-space drag direction.
    if (amount == null || _tools!._session != null) return;
    _tools!._suppressTap = true;
    _drag = _GizmoDrag(
      _tools!.beginTransform(selected),
      handle,
      _mode,
      effectiveSpace,
      event.pointer,
      inverse,
      viewport,
      _context!.camera,
      amount,
      size * _visuals.scale.x,
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

  UnlitMaterial _handleMaterial(int color) => UnlitMaterial(
    color: Color3.hex(color),
    alphaMode: alwaysVisible
        ? MaterialAlphaMode.blend
        : MaterialAlphaMode.opaque,
    depthTest: !alwaysVisible,
    depthWrite: alwaysVisible ? DepthWrite.disabled : DepthWrite.automatic,
  );

  void _buildHandles() {
    _frame.add(_visuals);
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
      _materials[axis] = _handleMaterial(axis.color);
    }
    for (final mode in GizmoMode.values) {
      final group = _visuals.add(Group(name: mode.name));
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
              renderOrder: alwaysVisible ? 0x7fffffff : 0,
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
      if (mode == GizmoMode.translate) {
        for (final plane in GizmoPlane.values) {
          _materials[plane] = _handleMaterial(plane.color);
          final normal = plane.perpendicular.direction;
          final pad = group.add(
            Mesh(
              BoxGeometry(
                width: size * (normal.x == 1 ? .025 : .22),
                height: size * (normal.y == 1 ? .025 : .22),
                depth: size * (normal.z == 1 ? .025 : .22),
              ),
              _materials[plane]!,
              name: 'translate ${plane.name}',
              renderOrder: alwaysVisible ? 0x7fffffff : 0,
            ),
          );
          pad.position =
              (plane.first.direction + plane.second.direction) * (size * .65);
          _handles[pad] = plane;
        }
      }
    }
    _root.visible = false;
  }
}

final class _GizmoDrag {
  final TransformSession session;
  final GizmoHandle handle;
  final GizmoMode mode;
  final GizmoSpace space;
  final int pointer, cameraRevision;
  final Camera camera;
  final Mat4 inverse, parentInverse;
  final double handedness;
  final double radius;
  final ViewportMetrics viewport;
  final Vec3 start;
  final _Pose pose;
  double previous, angle = 0;
  _GizmoDrag(
    this.session,
    this.handle,
    this.mode,
    this.space,
    this.pointer,
    this.inverse,
    this.viewport,
    this.camera,
    this.start,
    this.radius,
  ) : cameraRevision = camera.revision,
      parentInverse = _world(session.object.parent!).inverted(),
      handedness = _handedness(_world(session.object.parent!)),
      pose = _Pose.capture(session.object),
      previous = start.x;
}

List<Vec3> _basis(Mat4 matrix) => [
  Vec3.array(matrix.storage, 0),
  Vec3.array(matrix.storage, 4),
  Vec3.array(matrix.storage, 8),
];
double _handedness(Mat4 matrix) {
  final b = _basis(matrix);
  return b[0].cross(b[1]).dot(b[2]) < 0 ? -1 : 1;
}

bool _similarity(Mat4 matrix) {
  final b = _basis(matrix);
  final length = b[0].length;
  if (!length.isFinite || length == 0) return false;
  final unit = b.map((v) => v / length).toList();
  return unit.every((v) => (v.length2 - 1).abs() < 1e-8) &&
      unit[0].dot(unit[1]).abs() < 1e-8 &&
      unit[1].dot(unit[2]).abs() < 1e-8 &&
      unit[0].dot(unit[2]).abs() < 1e-8;
}

Vec3? _sample(CameraRay ray, GizmoHandle handle, GizmoMode mode) {
  if (handle is GizmoAxis) {
    final amount = _amount(ray, handle, mode);
    return amount == null ? null : Vec3(amount, 0, 0);
  }
  final normal = (handle as GizmoPlane).perpendicular.direction;
  final denominator = ray.direction.dot(normal);
  if (denominator.abs() < .025) return null;
  final t = -ray.origin.dot(normal) / denominator;
  return t < 0 ? null : ray.at(t);
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
