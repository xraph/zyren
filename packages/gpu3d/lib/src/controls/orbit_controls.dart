import 'dart:async';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../input/pointer_event.dart';
import '../input/viewport_input.dart';
import '../input/viewport_point.dart';
import '../math/quat.dart';
import '../math/vec3.dart';
import '../scene/scene.dart';

enum OrbitAction { none, rotate, dolly, pan, dollyPan, dollyRotate }

enum OrbitEvent { start, change, end }

/// Native port of three-stdlib 2.36.1 OrbitControls, as used by Drei 10.7.7.
/// Damping and auto-rotation advance once per update, matching that version.
class OrbitControls {
  final Camera camera;
  ViewportMetrics viewport;
  Vec3 target;
  bool enabled = true, enableZoom = true, enableRotate = true, enablePan = true;
  bool enableDamping = false, screenSpacePanning = true, zoomToCursor = false;
  bool reverseOrbit = false,
      reverseHorizontalOrbit = false,
      reverseVerticalOrbit = false;
  double minDistance = 0, maxDistance = double.infinity;
  double minZoom = 0, maxZoom = double.infinity;
  double minPolarAngle = 0, maxPolarAngle = math.pi;
  double minAzimuthAngle = double.negativeInfinity,
      maxAzimuthAngle = double.infinity;
  double dampingFactor = .05, zoomSpeed = 1, rotateSpeed = 1, panSpeed = 1;
  double keyPanSpeed = 7, autoRotateSpeed = 2;
  OrbitAction primary = OrbitAction.rotate,
      middle = OrbitAction.dolly,
      secondary = OrbitAction.pan;
  OrbitAction oneTouch = OrbitAction.rotate, twoTouch = OrbitAction.dollyPan;
  final Map<SceneKey, ViewportPoint> keys = {
    SceneKey.arrowLeft: const ViewportPoint(1, 0),
    SceneKey.arrowRight: const ViewportPoint(-1, 0),
    SceneKey.arrowUp: const ViewportPoint(0, 1),
    SceneKey.arrowDown: const ViewportPoint(0, -1),
  };
  final void Function()? requestFrame;
  final _events = StreamController<OrbitEvent>.broadcast(sync: true);
  Stream<OrbitEvent> get events => _events.stream;
  bool _autoRotate = false, _closed = false;
  bool get autoRotate => _autoRotate;
  set autoRotate(bool value) {
    _checkOpen();
    _autoRotate = value;
    requestFrame?.call();
  }

  OrbitAction _action = OrbitAction.none;
  final _pointers = <int, ViewportPoint>{}, _starts = <int, ViewportPoint>{};
  ViewportPoint _start = const ViewportPoint(0, 0),
      _mouse = const ViewportPoint(0, 0);
  double _pinch = 0, _thetaDelta = 0, _phiDelta = 0, _scale = 1;
  double _theta = 0, _phi = 0;
  Vec3 _pan = Vec3.zero, _dollyDirection = Vec3.zero, _lastPosition = Vec3.zero;
  Quat _lastQuaternion = Quat.identity;
  bool _cursorZoom = false, _touchInteraction = false;
  Object? _lastViewState;
  Object get _viewState => (
    camera.position,
    camera.target,
    camera.up,
    target,
    zoom,
    minDistance,
    maxDistance,
    minZoom,
    maxZoom,
    minPolarAngle,
    maxPolarAngle,
    minAzimuthAngle,
    maxAzimuthAngle,
    enableDamping,
    dampingFactor,
  );
  late Vec3 _savedTarget, _savedPosition;
  late double _savedZoom;

  OrbitControls(
    this.camera, {
    Vec3? target,
    this.viewport = const ViewportMetrics(1, 1),
    this.requestFrame,
  }) : target = target ?? Vec3.zero {
    if (camera is! PerspectiveCamera && camera is! OrthographicCamera) {
      throw ArgumentError(
        'Orbit controls require a perspective or orthographic camera.',
      );
    }
    saveState();
    update();
  }

  double get distance => camera.position.distanceTo(target);
  double get polarAngle => _phi;
  double get azimuthalAngle => _theta;
  double get zoom => switch (camera) {
    PerspectiveCamera c => c.zoom,
    OrthographicCamera c => c.zoom,
    _ => throw StateError('Unsupported camera'),
  };
  void _setZoom(double value) {
    switch (camera) {
      case PerspectiveCamera c:
        c.zoom = value;
      case OrthographicCamera c:
        c.zoom = value;
    }
  }

  bool get isInteracting => _action != OrbitAction.none;
  bool get needsUpdate =>
      !_closed &&
      (autoRotate ||
          _viewState != _lastViewState ||
          ((!enableDamping || dampingFactor > 0) &&
              (_thetaDelta.abs() > 1e-12 ||
                  _phiDelta.abs() > 1e-12 ||
                  _pan.length2 > 1e-24)));

  void saveState() {
    _checkOpen();
    _savedTarget = target;
    _savedPosition = camera.position;
    _savedZoom = zoom;
  }

  void reset() {
    _checkOpen();
    target = _savedTarget;
    camera.position = _savedPosition;
    _setZoom(_savedZoom);
    _events.add(OrbitEvent.change);
    update();
    _action = OrbitAction.none;
    requestFrame?.call();
  }

  double getZoomScale() => math.pow(.95, zoomSpeed).toDouble();
  void dollyIn([double? factor]) =>
      setScale(_scale * (factor ?? getZoomScale()));
  void dollyOut([double? factor]) =>
      setScale(_scale / (factor ?? getZoomScale()));
  double getScale() => _scale;
  void setScale(double value) {
    _checkOpen();
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(value, 'scale');
    }
    _scale = value;
    update();
    requestFrame?.call();
  }

  void setPolarAngle(double value) {
    _phiDelta = _angleDelta(value, _phi);
    update();
    requestFrame?.call();
  }

  void setAzimuthalAngle(double value) {
    _thetaDelta = _angleDelta(value, _theta);
    update();
    requestFrame?.call();
  }

  double _angleDelta(double value, double current) {
    if (!value.isFinite) throw ArgumentError.value(value, 'angle');
    var next = value % (2 * math.pi), previous = current;
    if (previous < 0) previous += 2 * math.pi;
    final difference = (next - previous).abs();
    if (2 * math.pi - difference < difference) {
      if (next < previous) {
        next += 2 * math.pi;
      } else {
        previous += 2 * math.pi;
      }
    }
    return next - previous;
  }

  /// Disabled controls ignore new input; cancellation still releases pointers.
  void handlePointer(ScenePointerEvent event) {
    _checkOpen();
    if (event.phase == ScenePointerPhase.up ||
        event.phase == ScenePointerPhase.cancel) {
      if (!_pointers.containsKey(event.pointer)) return;
      _pointers.remove(event.pointer);
      _starts.remove(event.pointer);
      _action = OrbitAction.none;
      _events.add(OrbitEvent.end);
      return;
    }
    if (!enabled || !viewport.isUsable) return;
    final point = event.point;
    if (!point.x.isFinite || !point.y.isFinite) return;
    final touch = event.kind == ScenePointerKind.touch;
    switch (event.phase) {
      case ScenePointerPhase.down:
        _touchInteraction = touch;
        _pointers[event.pointer] = point;
        _starts[event.pointer] = point;
        if (touch) {
          _action = switch (_pointers.length) {
            1 => oneTouch,
            2 => twoTouch,
            _ => OrbitAction.none,
          };
          _start = _touchCenter(_starts);
          _pinch = _touchDistance(_starts);
        } else {
          _action = switch (event.buttons) {
            1 => primary,
            4 => middle,
            2 => secondary,
            _ => OrbitAction.none,
          };
          if (event.modifiers.any(
            {
              SceneModifier.control,
              SceneModifier.meta,
              SceneModifier.shift,
            }.contains,
          )) {
            if (_action == OrbitAction.rotate) {
              _action = OrbitAction.pan;
            } else if (_action == OrbitAction.pan) {
              _action = OrbitAction.rotate;
            }
          }
          _start = point;
          if (_action == OrbitAction.dolly) _mouseParameters(point);
        }
        if (!_actionEnabled()) _action = OrbitAction.none;
        if (isInteracting) _events.add(OrbitEvent.start);
      case ScenePointerPhase.move:
        if (!_pointers.containsKey(event.pointer) ||
            !isInteracting ||
            !_actionEnabled()) {
          return;
        }
        _pointers[event.pointer] = point;
        final current = touch ? _touchCenter(_pointers) : point;
        final dx = current.x - _start.x, dy = current.y - _start.y;
        if (touch &&
            (_action == OrbitAction.dollyPan ||
                _action == OrbitAction.dollyRotate)) {
          final next = _touchDistance(_pointers);
          if (enableZoom && _pinch > 0 && next > 0) {
            _scale /= math.pow(next / _pinch, zoomSpeed);
          }
          _pinch = next;
        }
        if (enableRotate &&
            (_action == OrbitAction.rotate ||
                _action == OrbitAction.dollyRotate)) {
          _rotate(dx * rotateSpeed, dy * rotateSpeed);
        }
        if (enablePan &&
            (_action == OrbitAction.pan || _action == OrbitAction.dollyPan)) {
          _panBy(dx * panSpeed, dy * panSpeed);
        }
        if (enableZoom && _action == OrbitAction.dolly && dy != 0) {
          _scale *= dy < 0 ? getZoomScale() : 1 / getZoomScale();
        }
        _start = current;
        update();
        requestFrame?.call();
      case ScenePointerPhase.scroll:
        if (!enableZoom ||
            (isInteracting &&
                (_action != OrbitAction.rotate || _touchInteraction)) ||
            !event.delta.y.isFinite) {
          return;
        }
        _events.add(OrbitEvent.start);
        _mouseParameters(point);
        if (event.delta.y != 0) {
          _scale *= event.delta.y < 0 ? getZoomScale() : 1 / getZoomScale();
        }
        update();
        requestFrame?.call();
        _events.add(OrbitEvent.end);
      default:
        break;
    }
  }

  bool _actionEnabled() => switch (_action) {
    OrbitAction.rotate => enableRotate,
    OrbitAction.pan => enablePan,
    OrbitAction.dolly => enableZoom,
    OrbitAction.dollyPan => enableZoom || enablePan,
    OrbitAction.dollyRotate => enableZoom || enableRotate,
    OrbitAction.none => false,
  };
  void handleKey(SceneKeyEvent event) {
    _checkOpen();
    if (!enabled ||
        !enablePan ||
        !viewport.isUsable ||
        (event.phase != SceneKeyPhase.down &&
            event.phase != SceneKeyPhase.repeat)) {
      return;
    }
    final direction = keys[event.key];
    if (direction == null) return;
    _panBy(direction.x * keyPanSpeed, direction.y * keyPanSpeed);
    update();
    requestFrame?.call();
  }

  void _rotate(double dx, double dy) {
    _thetaDelta +=
        2 *
        math.pi *
        dx /
        viewport.height *
        (reverseOrbit || reverseHorizontalOrbit ? 1 : -1);
    _phiDelta +=
        2 *
        math.pi *
        dy /
        viewport.height *
        (reverseOrbit || reverseVerticalOrbit ? 1 : -1);
  }

  void _panBy(double dx, double dy) {
    final back = (camera.position - camera.target).normalized();
    final right = camera.up.cross(back).normalized();
    final up = screenSpacePanning ? back.cross(right) : camera.up.cross(right);
    final (x, y) = switch (camera) {
      PerspectiveCamera c => (
        2 * dx * distance * math.tan(c.fieldOfView / 2) / viewport.height,
        2 * dy * distance * math.tan(c.fieldOfView / 2) / viewport.height,
      ),
      OrthographicCamera c => (
        dx * (c.right - c.left) / c.zoom / viewport.width,
        dy * (c.top - c.bottom) / c.zoom / viewport.height,
      ),
      _ => (0.0, 0.0),
    };
    _pan += right * -x + up * y;
  }

  void _mouseParameters(ViewportPoint point) {
    if (!zoomToCursor) return;
    _cursorZoom = true;
    _mouse = ViewportPoint(
      point.x / viewport.width * 2 - 1,
      1 - point.y / viewport.height * 2,
    );
    _dollyDirection = camera
        .rayFromNdc(_mouse.x, _mouse.y, viewport.aspect)
        .direction;
  }

  bool update() {
    _checkOpen();
    _validate();
    final orientationBeforeUpdate = camera.quaternion;
    final quat = _upToY(camera.up.normalized());
    final inverse = Quat(-quat.x, -quat.y, -quat.z, quat.w);
    var offset = quat.rotate(camera.position - target);
    var radius = offset.length;
    if (radius == 0) {
      throw ArgumentError('Orbit position must differ from target.');
    }
    _theta = math.atan2(offset.x, offset.z);
    _phi = math.acos((offset.y / radius).clamp(-1.0, 1.0));
    if (autoRotate && !isInteracting) {
      _thetaDelta +=
          2 *
          math.pi /
          60 /
          60 *
          autoRotateSpeed *
          (reverseOrbit || reverseHorizontalOrbit ? 1 : -1);
    }
    final factor = enableDamping ? dampingFactor : 1.0;
    _theta += _thetaDelta * factor;
    _phi += _phiDelta * factor;
    var min = minAzimuthAngle, max = maxAzimuthAngle;
    if (min.isFinite && max.isFinite) {
      if (min < -math.pi) {
        min += 2 * math.pi;
      } else if (min > math.pi) {
        min -= 2 * math.pi;
      }
      if (max < -math.pi) {
        max += 2 * math.pi;
      } else if (max > math.pi) {
        max -= 2 * math.pi;
      }
      _theta = min <= max
          ? _theta.clamp(min, max)
          : (_theta > (min + max) / 2
                ? math.max(min, _theta)
                : math.min(max, _theta));
    }
    _phi = _phi.clamp(minPolarAngle, maxPolarAngle).clamp(1e-6, math.pi - 1e-6);
    target += _pan * factor;
    radius = _clampDistance(
      radius *
          ((zoomToCursor && _cursorZoom) || camera is OrthographicCamera
              ? 1
              : _scale),
    );
    final sinPhiRadius = math.sin(_phi) * radius;
    offset = inverse.rotate(
      Vec3(
        sinPhiRadius * math.sin(_theta),
        math.cos(_phi) * radius,
        sinPhiRadius * math.cos(_theta),
      ),
    );
    camera.position = target + offset;
    _lookAt();
    _thetaDelta *= 1 - factor;
    _phiDelta *= 1 - factor;
    _pan *= 1 - factor;
    var zoomChanged = false;
    if (zoomToCursor && _cursorZoom) {
      final forward = (camera.target - camera.position).normalized();
      double newRadius;
      if (camera is PerspectiveCamera) {
        newRadius = _clampDistance(offset.length * _scale);
        camera.position += _dollyDirection * (offset.length - newRadius);
      } else {
        final orthographic = camera as OrthographicCamera;
        final previousZoom = zoom;
        _setZoom(_clampZoom(zoom / _scale));
        zoomChanged = true;
        // stdlib unprojects with the world matrix cached before lookAt updates
        // its quaternion. Retain that orientation during damped cursor zoom.
        final deltaZoom = 1 / previousZoom - 1 / zoom;
        camera.position += orientationBeforeUpdate.rotate(
          Vec3(
            _mouse.x * (orthographic.right - orthographic.left) * deltaZoom / 2,
            _mouse.y * (orthographic.top - orthographic.bottom) * deltaZoom / 2,
            0,
          ),
        );
        newRadius = offset.length;
      }
      if (screenSpacePanning) {
        target = camera.position + forward * newRadius;
      } else if (camera.up.dot(forward).abs() >= math.cos(70 * math.pi / 180)) {
        final t =
            (target - camera.position).dot(camera.up) / forward.dot(camera.up);
        if (t >= 0) target = camera.position + forward * t;
      }
      _lookAt();
    } else if (camera is OrthographicCamera && _scale != 1) {
      zoomChanged = true;
      _setZoom(_clampZoom(zoom / _scale));
    }
    _scale = 1;
    _cursorZoom = false;
    _lastViewState = _viewState;
    final q = camera.quaternion, last = _lastQuaternion;
    final dot = q.x * last.x + q.y * last.y + q.z * last.z + q.w * last.w;
    if (zoomChanged ||
        (camera.position - _lastPosition).length2 > 1e-6 ||
        8 * (1 - dot) > 1e-6) {
      _lastPosition = camera.position;
      _lastQuaternion = q;
      _events.add(OrbitEvent.change);
      return true;
    }
    return false;
  }

  double _clampDistance(double value) =>
      value.clamp(math.max(1e-12, minDistance), maxDistance);
  double _clampZoom(double value) =>
      value.clamp(math.max(1e-12, minZoom), maxZoom);
  void _lookAt() {
    camera.target = target;
    final back = (camera.position - target).normalized();
    final right = camera.up.cross(back).normalized(), up = back.cross(right);
    final matrix = vm.Matrix3.identity()
      ..setColumn(0, right.toVectorMath())
      ..setColumn(1, up.toVectorMath())
      ..setColumn(2, back.toVectorMath());
    camera.quaternion = Quat.fromVectorMath(vm.Quaternion.fromRotation(matrix));
  }

  void _validate() {
    if (!target.isFinite ||
        !dampingFactor.isFinite ||
        dampingFactor < 0 ||
        dampingFactor > 1 ||
        !minDistance.isFinite ||
        minDistance < 0 ||
        maxDistance.isNaN ||
        maxDistance < 1e-12 ||
        maxDistance < minDistance ||
        !minZoom.isFinite ||
        minZoom < 0 ||
        maxZoom.isNaN ||
        maxZoom < 1e-12 ||
        maxZoom < minZoom ||
        !minPolarAngle.isFinite ||
        !maxPolarAngle.isFinite ||
        minPolarAngle > maxPolarAngle ||
        minAzimuthAngle.isNaN ||
        maxAzimuthAngle.isNaN ||
        [
          zoomSpeed,
          rotateSpeed,
          panSpeed,
          keyPanSpeed,
          autoRotateSpeed,
        ].any((v) => !v.isFinite)) {
      throw ArgumentError('Invalid orbit configuration.');
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Orbit controls are disposed.');
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _pointers.clear();
    _starts.clear();
    unawaited(_events.close());
  }
}

ViewportPoint _touchCenter(Map<int, ViewportPoint> points) {
  if (points.length == 1) return points.values.first;
  final values = points.values.take(2).toList();
  return ViewportPoint(
    (values[0].x + values[1].x) / 2,
    (values[0].y + values[1].y) / 2,
  );
}

double _touchDistance(Map<int, ViewportPoint> points) {
  if (points.length < 2) return 0;
  final values = points.values.take(2).toList();
  return math.sqrt(
    math.pow(values[0].x - values[1].x, 2) +
        math.pow(values[0].y - values[1].y, 2),
  );
}

Quat _upToY(Vec3 up) {
  final r = up.y + 1;
  if (r < 2.220446049250313e-16) {
    return (up.x.abs() > up.z.abs()
            ? Quat(-up.y, up.x, 0, 0)
            : Quat(0, -up.z, up.y, 0))
        .normalized();
  }
  return Quat(-up.z, 0, up.x, r).normalized();
}
