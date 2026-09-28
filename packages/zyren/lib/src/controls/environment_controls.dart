// Adapted from 3d-tiles-renderer 0.4.24 EnvironmentControls and PointerTracker.
// Copyright 2020 California Institute of Technology. Apache-2.0.
// Modified for Dart values, native input, surface queries and cancellation.
// See licenses/3d-tiles-renderer.txt at the repository root.
import 'dart:async';
import 'dart:math' as math;
import '../input/pointer_event.dart';
import '../input/viewport_input.dart';
import '../input/viewport_point.dart';
import '../math/quat.dart';
import '../math/vec3.dart';
import '../scene/scene.dart';
import '../spatial/raycaster.dart';

enum EnvironmentState { none, drag, rotate, zoom, waiting }

enum NavigationEvent { start, change, end }

enum ScrollDeltaMode { pixels, lines, pages }

/// A surface query result in world coordinates and world distance units.
final class NavigationHit {
  final Vec3 point;
  final double distance;
  NavigationHit(this.point, this.distance) {
    if (!point.isFinite || !distance.isFinite) {
      throw ArgumentError('A navigation hit must be finite.');
    }
  }
}

typedef NavigationSurfaceQuery = NavigationHit? Function(CameraRay ray);

/// Surface navigation following 3d-tiles-renderer 0.4.24.
///
/// Input uses logical pixels. Call [update] once per frame after delivering all
/// input for that frame. Subclasses can supply curved surfaces and local up via
/// [raycast] and [getUpDirection] without accessing a native renderer.
class EnvironmentControls {
  final Camera camera;
  final Scene? scene;
  final NavigationSurfaceQuery? surfaceQuery;
  final void Function()? requestFrame;
  final _picker = Raycaster();
  final _events = StreamController<NavigationEvent>.broadcast(sync: true);
  Stream<NavigationEvent> get events => _events.stream;
  ViewportMetrics viewport;
  bool _enabled = true, _closed = false, pendingUpdate = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    checkOpen();
    if (_enabled == value) return;
    _enabled = value;
    cancel();
  }

  Vec3 up = const Vec3(0, 1, 0);
  Vec3 fallbackPlaneNormal = const Vec3(0, 1, 0);
  double fallbackPlaneConstant = 0;
  bool useFallbackPlane = true, adjustHeight = true;
  bool enableDamping = false, autoAdjustCameraRotation = true;
  bool scaleZoomOrientationAtEdges = false;
  double cameraRadius = 5, rotationSpeed = 1, zoomSpeed = 1;
  double minAltitude = 0, maxAltitude = .45 * math.pi;
  double minDistance = 10, maxDistance = double.infinity;
  double minZoom = 0, maxZoom = double.infinity, dampingFactor = .15;
  EnvironmentState state = EnvironmentState.none;
  EnvironmentState lastUsedState = EnvironmentState.none;
  Vec3 pivotPoint = Vec3.zero, zoomPoint = Vec3.zero;
  Vec3 zoomDirection = const Vec3(0, 0, -1);
  bool zoomPointSet = false, zoomDirectionSet = false, zoomPointWasSet = false;
  double zoomDelta = 0, actionHeightOffset = 0;
  Vec3 dragInertia = Vec3.zero;
  ViewportPoint rotationInertia = const ViewportPoint(0, 0);
  double inertiaTargetDistance = double.infinity;
  int inertiaStableFrames = 0;
  final _pointers = <int, _Pointer>{};
  ScenePointerKind? _pointerKind;
  int _buttons = 0;
  ViewportPoint? _hover;
  ViewportPoint? _lastZoomPointer;
  bool _touchMoved = false, _upInitialized = false;

  EnvironmentControls(
    this.camera, {
    this.scene,
    this.surfaceQuery,
    this.requestFrame,
    this.viewport = const ViewportMetrics(800, 600),
  });

  bool get needsUpdate => enabled && (pendingUpdate || inertiaNeedsUpdate);
  bool get inertiaNeedsUpdate =>
      dragInertia.length2 != 0 || _length2(rotationInertia) != 0;
  Vec3 get forward => (camera.target - camera.position).normalized();
  Vec3 get right => forward.cross(camera.up).normalized();
  ViewportPoint? get pointer =>
      _pointers.isEmpty ? _hover : _center((p) => p.position);
  ViewportPoint get previousPointer => _center((p) => p.previous);
  double get pointerMoveDistance =>
      _distance(_center((p) => p.position), previousPointer);
  Vec3 getUpDirection(Vec3 point) => up;
  Vec3 getCameraUpDirection() => getUpDirection(camera.position);

  void wake() {
    pendingUpdate = true;
    requestFrame?.call();
  }

  void handlePointer(ScenePointerEvent event) {
    checkOpen();
    if (!enabled) return;
    if (event.phase == ScenePointerPhase.cancel) {
      cancel();
      return;
    }
    if (!viewport.isUsable) {
      cancel();
      return;
    }
    if (!event.point.x.isFinite || !event.point.y.isFinite) {
      throw ArgumentError('Pointer must be finite.');
    }
    switch (event.phase) {
      case ScenePointerPhase.down:
        if (_pointers.containsKey(event.pointer)) return;
        _pointers[event.pointer] = _Pointer(event.point);
        if (_pointers.length == 1) {
          _pointerKind = event.kind;
          _buttons = event.buttons;
        }
        wake();
        if (_pointers.length > 2) {
          resetState();
          return;
        }
        final ray = pointerRay(pointer!);
        if (ray.direction.dot(up).abs() < .05) return;
        final hit = raycast(ray);
        if (hit == null) return;
        if (_pointers.length == 2 ||
            _buttons & 2 != 0 ||
            (_buttons & 1 != 0 &&
                event.modifiers.contains(SceneModifier.shift))) {
          pivotPoint = hit.point;
          setState(
            _pointerKind == ScenePointerKind.touch
                ? EnvironmentState.waiting
                : EnvironmentState.rotate,
          );
        } else if (_buttons & 1 != 0) {
          pivotPoint = hit.point;
          setState(EnvironmentState.drag);
        }
      case ScenePointerPhase.move:
      case ScenePointerPhase.hover:
        zoomDirectionSet = zoomPointSet = false;
        if (state != EnvironmentState.none) wake();
        if (event.kind == ScenePointerKind.mouse) _hover = event.point;
        final p = _pointers[event.pointer];
        if (p == null) return;
        p.position = event.point;
        _touchMoved =
            _pointerKind == ScenePointerKind.touch && _pointers.length == 2;
        emit(NavigationEvent.change);
      case ScenePointerPhase.up:
        if (_pointers.isEmpty) return;
        resetState();
        wake();
      case ScenePointerPhase.scroll:
        handleWheel(event.point, event.delta.y);
      default:
        break;
    }
  }

  void handleWheel(
    ViewportPoint point,
    double deltaY, {
    ScrollDeltaMode mode = ScrollDeltaMode.pixels,
  }) {
    checkOpen();
    if (!enabled || !viewport.isUsable) return;
    if (!deltaY.isFinite || !point.x.isFinite || !point.y.isFinite) {
      throw ArgumentError('Wheel input must be finite.');
    }
    if (_hover?.x != point.x || _hover?.y != point.y) {
      zoomDirectionSet = zoomPointSet = false;
    }
    _hover = point;
    emit(NavigationEvent.start);
    zoomDelta -=
        .25 *
        deltaY *
        switch (mode) {
          ScrollDeltaMode.pixels => 1,
          ScrollDeltaMode.lines => 40,
          ScrollDeltaMode.pages => 800,
        };
    lastUsedState = EnvironmentState.zoom;
    wake();
    emit(NavigationEvent.end);
  }

  void resetState() {
    checkOpen();
    if (state != EnvironmentState.none) emit(NavigationEvent.end);
    state = EnvironmentState.none;
    actionHeightOffset = 0;
    _pointers.clear();
    _pointerKind = null;
    _buttons = 0;
    _hover = null;
    _touchMoved = false;
  }

  /// Cancels interrupted input and all residual motion, including queued zoom.
  void cancel() {
    resetState();
    dragInertia = Vec3.zero;
    rotationInertia = const ViewportPoint(0, 0);
    zoomDelta = 0;
    _lastZoomPointer = null;
    pendingUpdate = false;
    zoomDirectionSet = zoomPointSet = false;
  }

  void setState(EnvironmentState value) {
    if (state == value) return;
    if (state == EnvironmentState.none) emit(NavigationEvent.start);
    dragInertia = Vec3.zero;
    rotationInertia = const ViewportPoint(0, 0);
    inertiaStableFrames = 0;
    state = value;
    if (value != EnvironmentState.none && value != EnvironmentState.waiting) {
      lastUsedState = value;
    }
  }

  void _resolveTouch() {
    if (!_touchMoved || _pointers.length != 2) return;
    _touchMoved = false;
    final values = _pointers.values.toList();
    final distance = _distance(values[0].position, values[1].position);
    final start = _distance(values[0].start, values[1].start);
    if (state == EnvironmentState.none || state == EnvironmentState.waiting) {
      final parallel = _distance(pointer!, _center((p) => p.start));
      final separation = (distance - start).abs();
      final threshold = 2 * viewport.devicePixelRatio;
      if (separation > threshold || parallel > threshold) {
        setState(
          separation > parallel
              ? EnvironmentState.zoom
              : EnvironmentState.rotate,
        );
        if (state == EnvironmentState.zoom) zoomDirectionSet = false;
      }
    }
    if (state == EnvironmentState.zoom) {
      zoomDelta += distance - _distance(values[0].previous, values[1].previous);
    }
  }

  void update(double deltaSeconds) {
    checkOpen();
    if (!deltaSeconds.isFinite || deltaSeconds < 0) {
      throw ArgumentError.value(deltaSeconds, 'deltaSeconds');
    }
    if (!enabled || deltaSeconds == 0 || !viewport.isUsable) return;
    _validate();
    _resolveTouch();
    if (!_upInitialized) {
      _upInitialized = true;
      up = getCameraUpDirection();
    }
    zoomPointSet = false;
    final inertia = inertiaNeedsUpdate,
        adjustRotation = pendingUpdate || inertiaNeedsUpdate;
    final action = state;
    if (pendingUpdate || inertia) {
      final delta = zoomDelta;
      updateZoom();
      updatePosition(deltaSeconds);
      updateRotation(deltaSeconds);
      if (action == EnvironmentState.drag || action == EnvironmentState.rotate) {
        inertiaTargetDistance = (pivotPoint - camera.position).dot(forward);
      } else if (action == EnvironmentState.none) {
        updateInertia(deltaSeconds);
      }
      if (action != EnvironmentState.none || delta != 0 || inertia) {
        emit(NavigationEvent.change);
      }
      pendingUpdate = false;
    }
    var hit = camera is PerspectiveCamera && adjustHeight
        ? getPointBelowCamera()
        : null;
    setFrame(getCameraUpDirection());
    if ((state == EnvironmentState.drag || state == EnvironmentState.rotate) &&
        actionHeightOffset != 0) {
      translate(up * -actionHeightOffset);
      pivotPoint -= up * actionHeightOffset;
      if (hit != null) {
        hit = NavigationHit(hit.point, hit.distance - actionHeightOffset);
      }
    }
    actionHeightOffset = 0;
    if (hit != null && hit.distance < cameraRadius) {
      final delta = cameraRadius - hit.distance;
      translate(up * delta);
      pivotPoint += up * delta;
      actionHeightOffset = delta;
    }
    for (final p in _pointers.values) {
      p.previous = p.position;
    }
    if (adjustRotation && autoAdjustCameraRotation) {
      alignCameraUp(getCameraUpDirection());
      clampRotation(getCameraUpDirection());
    }
    if (inertiaNeedsUpdate) requestFrame?.call();
  }

  CameraRay pointerRay(ViewportPoint point) {
    final ndc = point.toNdc(
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
    );
    final ray = camera.rayFromNdc(ndc.x, ndc.y, viewport.aspect);
    final near = camera is PerspectiveCamera
        ? (camera as PerspectiveCamera).near
        : (camera as OrthographicCamera).near;
    return CameraRay(
      ray.origin + ray.direction * (near / ray.direction.dot(forward)),
      ray.direction,
    );
  }

  NavigationHit? raycast(CameraRay ray) {
    final custom = surfaceQuery?.call(ray);
    if (custom != null && custom.distance >= 0) return custom;
    final root = scene;
    if (root != null) {
      final hits = _picker.intersectScene(root, ray);
      if (hits.isNotEmpty) {
        return NavigationHit(hits.first.point, hits.first.distance);
      }
    }
    if (!useFallbackPlane) return null;
    final point = planeIntersection(
      ray,
      fallbackPlaneNormal,
      fallbackPlaneConstant,
    );
    return point == null
        ? null
        : NavigationHit(point, point.distanceTo(ray.origin));
  }

  NavigationHit? getPointBelowCamera([Vec3? point, Vec3? localUp]) {
    final normal = localUp ?? up;
    final hit = raycast(
      CameraRay((point ?? camera.position) + normal * 1e5, -normal),
    );
    return hit == null ? null : NavigationHit(hit.point, hit.distance - 1e5);
  }

  void adjustCamera() {
    if (camera is! PerspectiveCamera || !adjustHeight) return;
    final normal = getCameraUpDirection(),
        hit = getPointBelowCamera(camera.position, getCameraUpDirection());
    if (hit != null && hit.distance < cameraRadius) {
      translate(normal * (cameraRadius - hit.distance));
    }
  }

  Vec3? getPivotPoint() {
    Vec3? result = switch (lastUsedState) {
      EnvironmentState.zoom => zoomPointWasSet ? zoomPoint : null,
      EnvironmentState.drag || EnvironmentState.rotate => pivotPoint,
      _ => null,
    };
    if (result != null) {
      final screen = camera.projectPoint(result, viewport.aspect);
      if (screen.x.abs() > 1 || screen.y.abs() > 1) result = null;
    }
    final ray = pointerRay(
      ViewportPoint(viewport.width / 2, viewport.height / 2),
    );
    final hit = raycast(ray);
    if (hit != null &&
        (result == null || hit.distance < result.distanceTo(ray.origin))) {
      result = hit.point;
    }
    return result;
  }

  void updateZoomDirection() {
    final point = pointer ?? _lastZoomPointer;
    if (zoomDirectionSet || point == null) return;
    _lastZoomPointer = point;
    zoomDirection = pointerRay(point).direction;
    zoomDirectionSet = true;
  }

  bool updateZoomPoint() {
    zoomPointWasSet = false;
    if (!zoomDirectionSet) return false;
    final ray = camera is OrthographicCamera && pointer != null
        ? pointerRay(pointer!)
        : CameraRay(camera.position, zoomDirection);
    final hit = raycast(ray);
    if (hit == null) return false;
    zoomPoint = hit.point;
    zoomPointSet = zoomPointWasSet = true;
    return true;
  }

  void updateZoom() {
    var scale = zoomDelta;
    zoomDelta = 0;
    final point = pointer;
    if (point == null || (scale == 0 && state != EnvironmentState.zoom)) return;
    dragInertia = Vec3.zero;
    rotationInertia = const ViewportPoint(0, 0);
    updateZoomDirection();
    final hit = zoomPointSet || updateZoomPoint(), c = camera;
    if (c is OrthographicCamera) {
      final before = pointerRay(point).origin;
      final normalized = math.pow(.95, (scale * .05).abs()).toDouble();
      var factor = (scale > 0 ? 1 / normalized : normalized) * zoomSpeed;
      if (factor > 1 ? maxZoom < c.zoom * factor : minZoom > c.zoom * factor) {
        factor = 1;
      }
      c.zoom *= factor;
      if (hit) translate(before - pointerRay(point).origin);
    } else if (hit) {
      final distance = zoomPoint.distanceTo(c.position);
      if (scale < 0) {
        scale = math.max(
          scale * distance * zoomSpeed * .0025,
          math.min(0, distance - maxDistance),
        );
      } else {
        scale = math.min(
          scale * math.max(distance - minDistance, 0) * zoomSpeed * .0025,
          math.max(0, distance - minDistance),
        );
      }
      translate(zoomDirection * scale);
    } else {
      final ground = getPointBelowCamera();
      if (ground != null) translate(forward * (scale * ground.distance * .01));
    }
  }

  void updatePosition(double dt) {
    if (state != EnvironmentState.drag || pointer == null) return;
    final ray = pointerRay(pointer!);
    var direction = ray.direction;
    for (final constraint in [(up, .05), (getUpDirection(pivotPoint), .025)]) {
      if (direction.dot(constraint.$1).abs() < constraint.$2) {
        direction = -Quat.axisAngle(
          direction.cross(constraint.$1),
          math.acos(constraint.$2),
        ).rotate(constraint.$1);
      }
    }
    final hit = planeIntersection(
      CameraRay(ray.origin, direction),
      up,
      -up.dot(pivotPoint),
    );
    if (hit == null) return;
    final delta = pivotPoint - hit;
    translate(delta);
    if (pointerMoveDistance / dt < 2 * viewport.devicePixelRatio) {
      inertiaStableFrames++;
    } else {
      dragInertia = delta / dt;
      inertiaStableFrames = 0;
    }
  }

  void updateRotation(double dt) {
    if (state != EnvironmentState.rotate || pointer == null) return;
    final delta = _subtract(pointer!, previousPointer),
        factor = 2 * math.pi / viewport.height;
    applyRotation(delta.x * factor, delta.y * factor, pivotPoint);
    if (pointerMoveDistance / dt < 2 * viewport.devicePixelRatio) {
      inertiaStableFrames++;
    } else {
      rotationInertia = ViewportPoint(
        delta.x * factor / dt,
        delta.y * factor / dt,
      );
      inertiaStableFrames = 0;
    }
  }

  void applyRotation(double x, double y, Vec3 pivot) {
    if (x == 0 && y == 0) return;
    final localUp = getUpDirection(pivot), back = -forward;
    final angle = signedAngle(localUp, back, right);
    var altitude = y * rotationSpeed;
    altitude = altitude > 0
        ? math.max(0, math.min(angle - minAltitude, altitude))
        : math.min(0, math.max(angle - maxAltitude, altitude));
    rotateAround(pivot, Quat.axisAngle(localUp, -x * rotationSpeed));
    rotateAround(pivot, Quat.axisAngle(right, -altitude));
  }

  void updateInertia(double dt) {
    if (!enableDamping || inertiaStableFrames > 1) {
      dragInertia = Vec3.zero;
      rotationInertia = const ViewportPoint(0, 0);
      return;
    }
    final factor = math.pow(2, -dt / dampingFactor).toDouble();
    final c = camera;
    final near = c is PerspectiveCamera
        ? c.near
        : (c as OrthographicCamera).near;
    final distance = [
      near,
      cameraRadius,
      minDistance,
      inertiaTargetDistance,
    ].reduce(math.max);
    // Match the upstream quarter pixel threshold at its notional 2000px width.
    final Vec3 delta;
    if (c is PerspectiveCamera) {
      final tangent = math.tan(c.fieldOfView / 2) / c.zoom;
      delta =
          right * (-.00025 * tangent * viewport.aspect * distance) +
          (-forward).cross(right) * (-.00025 * tangent * distance);
    } else {
      final ortho = c as OrthographicCamera;
      delta =
          right * (.00025 * (ortho.right - ortho.left) / (2 * ortho.zoom)) +
          (-forward).cross(right) *
              (.00025 * (ortho.top - ortho.bottom) / (2 * ortho.zoom));
    }
    if (_length2(rotationInertia) > 0) {
      final position = c.position - forward * distance;
      final a = position - pivotPoint, b = position + delta - pivotPoint;
      final threshold = vectorAngle(a, b) / dt;
      rotationInertia = ViewportPoint(
        rotationInertia.x * factor,
        rotationInertia.y * factor,
      );
      if (_length2(rotationInertia) < threshold * threshold) {
        rotationInertia = const ViewportPoint(0, 0);
      }
    }
    if (dragInertia.length2 > 0) {
      dragInertia *= factor;
      final threshold = delta.length / dt;
      if (dragInertia.length2 < threshold * threshold) dragInertia = Vec3.zero;
    }
    if (_length2(rotationInertia) > 0) {
      applyRotation(rotationInertia.x * dt, rotationInertia.y * dt, pivotPoint);
    }
    if (dragInertia.length2 > 0) translate(dragInertia * dt);
  }

  void setFrame(Vec3 newUp) {
    if (zoomDirectionSet && (zoomPointSet || updateZoomPoint())) {
      var q = navigationRotationBetween(up, newUp);
      if (scaleZoomOrientationAtEdges) {
        var amount = ((getUpDirection(zoomPoint).dot(up) - .6) / .4 * 2).clamp(
          0.0,
          1.0,
        );
        if (camera is OrthographicCamera) amount *= .1;
        q = navigationSlerp(Quat.identity, q, amount);
      }
      rotateAround(zoomPoint, q);
      zoomDirectionSet = false;
      updateZoomDirection();
    }
    up = newUp;
  }

  Vec3? get activePoint =>
      state == EnvironmentState.drag || state == EnvironmentState.rotate
      ? pivotPoint
      : zoomPointSet
      ? zoomPoint
      : null;
  void alignCameraUp(Vec3 normal, [double alpha = 1]) {
    final left = -right;
    alpha *= ((1 - forward.dot(normal).abs()) / .2).clamp(0, 1);
    final target = normal.cross(forward) * alpha + left * (1 - alpha);
    if (target.length2 < 1e-28) return;
    rotateAround(
      activePoint ?? camera.position,
      navigationRotationBetween(left, target.normalized()),
    );
  }

  void clampRotation(Vec3 normal) {
    final angle = signedAngle(normal, -forward, right);
    final target = angle.clamp(minAltitude, maxAltitude);
    if (angle == target) return;
    final back = Quat.axisAngle(right, target).rotate(normal).normalized();
    rotateAround(
      activePoint ?? camera.position,
      navigationRotationBetween(-forward, back),
    );
  }

  void translate(Vec3 delta) {
    camera.position += delta;
    camera.target += delta;
  }

  void rotateAround(Vec3 pivot, Quat rotation) {
    final f = rotation.rotate(forward),
        u = rotation.rotate((-forward).cross(right));
    final aimDistance = math.max(1.0, camera.target.distanceTo(camera.position));
    camera.position = pivot + rotation.rotate(camera.position - pivot);
    camera.target = camera.position + f * aimDistance;
    camera.up = u;
  }

  void emit(NavigationEvent event) => _events.add(event);
  void checkOpen() {
    if (_closed) throw StateError('Environment controls are disposed.');
  }

  void _validate() {
    if (!up.isFinite ||
        up.length2 == 0 ||
        !fallbackPlaneNormal.isFinite ||
        fallbackPlaneNormal.length2 == 0 ||
        !fallbackPlaneConstant.isFinite ||
        !dampingFactor.isFinite ||
        dampingFactor <= 0 ||
        !cameraRadius.isFinite ||
        cameraRadius < 0 ||
        !rotationSpeed.isFinite ||
        !zoomSpeed.isFinite ||
        zoomSpeed <= 0 ||
        !minAltitude.isFinite ||
        !maxAltitude.isFinite ||
        minAltitude > maxAltitude ||
        !minDistance.isFinite ||
        minDistance < 0 ||
        maxDistance.isNaN ||
        maxDistance < minDistance ||
        !minZoom.isFinite ||
        minZoom < 0 ||
        maxZoom.isNaN ||
        maxZoom < minZoom ||
        !viewport.devicePixelRatio.isFinite ||
        viewport.devicePixelRatio <= 0) {
      throw ArgumentError('Invalid environment controls settings.');
    }
  }

  ViewportPoint _center(ViewportPoint Function(_Pointer) get) {
    if (_pointers.isEmpty) return const ViewportPoint(0, 0);
    if (_pointers.length == 1 || _pointerKind == ScenePointerKind.mouse) {
      return get(_pointers.values.first);
    }
    final a = get(_pointers.values.first),
        b = get(_pointers.values.elementAt(1));
    return ViewportPoint((a.x + b.x) / 2, (a.y + b.y) / 2);
  }

  void dispose() {
    if (_closed) return;
    cancel();
    _closed = true;
    unawaited(_events.close());
  }
}

class _Pointer {
  ViewportPoint position, previous;
  final ViewportPoint start;
  _Pointer(this.position) : previous = position, start = position;
}

double _length2(ViewportPoint p) => p.x * p.x + p.y * p.y;
ViewportPoint _subtract(ViewportPoint a, ViewportPoint b) =>
    ViewportPoint(a.x - b.x, a.y - b.y);
double _distance(ViewportPoint a, ViewportPoint b) =>
    math.sqrt(_length2(_subtract(a, b)));
Vec3? planeIntersection(CameraRay ray, Vec3 normal, double constant) {
  final denominator = normal.dot(ray.direction),
      offset = normal.dot(ray.origin) + constant;
  if (denominator == 0) return offset == 0 ? ray.origin : null;
  final t = -offset / denominator;
  return t < 0 ? null : ray.at(t);
}

double vectorAngle(Vec3 a, Vec3 b) {
  final denominator = math.sqrt(a.length2 * b.length2);
  return denominator == 0
      ? math.pi / 2
      : math.acos((a.dot(b) / denominator).clamp(-1, 1));
}

double signedAngle(Vec3 up, Vec3 back, Vec3 right) => up.dot(back) > 1 - 1e-10
    ? 0
    : up.cross(back).dot(right).sign * vectorAngle(up, back);
Quat navigationRotationBetween(Vec3 from, Vec3 to) {
  final a = from.normalized(), b = to.normalized();
  final r = a.dot(b) + 1;
  if (r < 1e-15) {
    return (a.x.abs() > a.z.abs()
            ? Quat(-a.y, a.x, 0, 0)
            : Quat(0, -a.z, a.y, 0))
        .normalized();
  }
  final cross = a.cross(b);
  return Quat(cross.x, cross.y, cross.z, r).normalized();
}

Quat navigationSlerp(Quat a, Quat b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (dot < 0) {
    dot = -dot;
    b = Quat(-b.x, -b.y, -b.z, -b.w);
  }
  var x = 1 - t, y = t;
  if (dot < .9995) {
    final angle = math.acos(dot.clamp(-1, 1)), sin = math.sin(angle);
    x = math.sin((1 - t) * angle) / sin;
    y = math.sin(t * angle) / sin;
  }
  return Quat(
    a.x * x + b.x * y,
    a.y * x + b.y * y,
    a.z * x + b.z * y,
    a.w * x + b.w * y,
  ).normalized();
}
