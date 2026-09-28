// Adapted from 3d-tiles-renderer 0.4.24 CameraTransitionManager.
// Copyright 2020 California Institute of Technology. Apache-2.0.
// Modified for Dart camera values, typed events and explicit elapsed time.
// See licenses/3d-tiles-renderer.txt at the repository root.
import 'dart:async';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../math/quat.dart';
import '../math/vec3.dart';
import '../scene/scene.dart';

enum CameraMode { perspective, orthographic }

enum CameraTransitionEventType {
  toggle('toggle'),
  change('change'),
  transitionStart('transition-start'),
  cameraChange('camera-change'),
  transitionEnd('transition-end');

  final String wireName;
  const CameraTransitionEventType(this.wireName);
}

/// A snapshot of the transition lifecycle; camera references remain live.
final class CameraTransitionEvent {
  final CameraTransitionEventType type;
  final Camera camera;
  final Camera? previousCamera;
  final double alpha;
  const CameraTransitionEvent(
    this.type,
    this.camera,
    this.alpha, [
    this.previousCamera,
  ]);
}

/// Projection transitions following 3d-tiles-renderer 0.4.24.
///
/// Call [update] with elapsed seconds, then render [camera]. The cameras share a
/// view direction and keep [fixedPoint] at the same apparent scale. As upstream,
/// perspective zoom should be one and orthographic bounds should be centered.
/// Camera ownership stays with the caller.
class CameraTransitionManager {
  final PerspectiveCamera perspectiveCamera;
  final OrthographicCamera orthographicCamera;
  final PerspectiveCamera transitionCamera = PerspectiveCamera();
  final _events = StreamController<CameraTransitionEvent>.broadcast(sync: true);
  Stream<CameraTransitionEvent> get events => _events.stream;
  bool _closed = false;
  double _alpha = 0;
  CameraMode _mode = CameraMode.perspective;
  Vec3 _fixedPoint = Vec3.zero;
  Duration _duration = const Duration(milliseconds: 200);
  double _orthographicOffset = 50;
  bool orthographicPositionalZoom = true;
  bool autoSync = true;
  double Function(double) easeFunction = _linear;
  static double _linear(double value) => value;

  CameraTransitionManager([
    PerspectiveCamera? perspectiveCamera,
    OrthographicCamera? orthographicCamera,
  ]) : perspectiveCamera = perspectiveCamera ?? PerspectiveCamera(),
       orthographicCamera = orthographicCamera ?? OrthographicCamera();

  Vec3 get fixedPoint => _fixedPoint;
  set fixedPoint(Vec3 value) {
    _checkOpen();
    if (!value.isFinite) throw ArgumentError.value(value, 'fixedPoint');
    _fixedPoint = value;
  }

  Duration get duration => _duration;
  set duration(Duration value) {
    _checkOpen();
    if (value <= Duration.zero) throw ArgumentError.value(value, 'duration');
    _duration = value;
  }

  double get orthographicOffset => _orthographicOffset;
  set orthographicOffset(double value) {
    _checkOpen();
    if (!value.isFinite) throw ArgumentError.value(value, 'orthographicOffset');
    _orthographicOffset = value;
  }

  bool get animating => _alpha != 0 && _alpha != 1;
  bool get needsUpdate => _alpha != _target;
  double get _target => _mode == CameraMode.perspective ? 0 : 1;
  double get alpha => _mode == CameraMode.perspective ? 1 - _alpha : _alpha;
  Camera get camera => _alpha == 0
      ? perspectiveCamera
      : _alpha == 1
      ? orthographicCamera
      : transitionCamera;
  CameraMode get mode => _mode;
  set mode(CameraMode value) {
    _checkOpen();
    if (value == _mode) return;
    final previous = camera;
    _mode = value;
    _alpha = _target;
    _emit(CameraTransitionEventType.cameraChange, previous);
  }

  void toggle() {
    _checkOpen();
    _mode = _mode == CameraMode.perspective
        ? CameraMode.orthographic
        : CameraMode.perspective;
    _emit(CameraTransitionEventType.toggle);
  }

  void update(double deltaSeconds) {
    _checkOpen();
    if (!deltaSeconds.isFinite || deltaSeconds < 0) {
      throw ArgumentError.value(deltaSeconds, 'deltaSeconds');
    }
    final next =
        (_alpha +
                (_target - _alpha).sign *
                    deltaSeconds *
                    1e6 /
                    duration.inMicroseconds)
            .clamp(0.0, 1.0);
    final eased = easeFunction(next);
    if (!eased.isFinite || eased < 0 || eased > 1) {
      throw ArgumentError.value(
        eased,
        'easeFunction',
        'Must return a value in [0, 1].',
      );
    }
    if (autoSync) syncCameras();
    final previous = camera;
    if (needsUpdate) {
      _alpha = next;
      _emit(CameraTransitionEventType.change);
    }
    if (animating) _updateTransitionCamera(eased);
    if (!identical(previous, camera)) {
      if (identical(camera, transitionCamera)) {
        _emit(CameraTransitionEventType.transitionStart);
      }
      _emit(CameraTransitionEventType.cameraChange, previous);
      if (identical(previous, transitionCamera)) {
        _emit(CameraTransitionEventType.transitionEnd);
      }
    }
  }

  void syncCameras() {
    _checkOpen();
    final p = perspectiveCamera, o = orthographicCamera;
    final fromPerspective = _target == _alpha
        ? _mode == CameraMode.perspective
        : _target > _alpha;
    final source = fromPerspective ? p : o;
    final basis = _orientation(source);
    final forward = basis.rotate(const Vec3(0, 0, -1));
    final tan = math.tan(p.fieldOfView / 2);
    if (fromPerspective) {
      final position = orthographicPositionalZoom
          ? p.position - forward * orthographicOffset
          : p.position +
                forward *
                    ((fixedPoint - p.position).dot(forward) -
                        (fixedPoint - o.position).dot(forward));
      _pose(o, position, basis);
      final distance = (p.position - fixedPoint).dot(forward).abs();
      if (distance == 0) {
        throw ArgumentError(
          'Fixed point must be away from the perspective camera plane.',
        );
      }
      o.zoom = (o.top - o.bottom) / (2 * tan * distance);
    } else {
      final distance = (o.position - fixedPoint).dot(forward).abs();
      final targetDistance = (o.top - o.bottom) / o.zoom * .5 / tan;
      _pose(p, o.position + forward * (distance - targetDistance), basis);
      if (orthographicPositionalZoom) {
        _pose(o, p.position - forward * orthographicOffset, basis);
      }
    }
    _pose(transitionCamera, p.position, _orientation(p));
  }

  void _updateTransitionCamera(double alpha) {
    final p = perspectiveCamera, o = orthographicCamera, t = transitionCamera;
    final pq = _orientation(p), oq = _orientation(o);
    final pf = pq.rotate(const Vec3(0, 0, -1));
    final of = oq.rotate(const Vec3(0, 0, -1));
    // Upstream snapshots the shifted orthographic camera before normalizing its
    // stored clipping range. Preserve that ordering for subsequent updates.
    final orthoPosition = o.position + of * o.near;
    final orthoNear = o.near, orthoFar = o.far;
    o.setClippingRange(0, o.far - o.near);
    final height =
        2 *
        math.tan(p.fieldOfView / 2) *
        (p.position - fixedPoint).dot(pf).abs();
    final fov = _lerp(p.fieldOfView, math.pi / 180, alpha);
    final distance = height * .5 / math.tan(fov / 2);
    final po = _inverse(pq).rotate(p.position - fixedPoint);
    final oo = _inverse(oq).rotate(orthoPosition - fixedPoint);
    final offset = po * (1 - alpha) + oo * alpha;
    final targetOffset = Vec3(
      offset.x,
      offset.y,
      offset.z - offset.z.abs() + distance,
    );
    final near = _lerp(
      targetOffset.z - po.z + p.near,
      targetOffset.z - oo.z + orthoNear,
      alpha,
    );
    final far = _lerp(
      targetOffset.z - po.z + p.far,
      targetOffset.z - oo.z + orthoFar,
      alpha,
    );
    final planeDelta = math.max(far, 0) - math.max(near, 0);
    t.fieldOfView = fov;
    t.setClippingRange(math.max(near, planeDelta * 1e-5), far);
    final q = _slerp(pq, oq, alpha);
    _pose(t, q.rotate(targetOffset) + fixedPoint, q);
  }

  void _emit(CameraTransitionEventType type, [Camera? previous]) =>
      _events.add(CameraTransitionEvent(type, camera, alpha, previous));
  void _checkOpen() {
    if (_closed) throw StateError('Camera transition manager is disposed.');
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_events.close());
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
Quat _inverse(Quat q) => Quat(-q.x, -q.y, -q.z, q.w);
Quat _orientation(Camera camera) {
  final back = (camera.position - camera.target).normalized();
  final right = camera.up.cross(back).normalized();
  return Quat.fromVectorMath(
    vm.Quaternion.fromRotation(
      vm.Matrix3.columns(
        right.toVectorMath(),
        back.cross(right).toVectorMath(),
        back.toVectorMath(),
      ),
    ),
  ).normalized();
}

void _pose(Camera camera, Vec3 position, Quat rotation) {
  camera.position = position;
  camera.target = position + rotation.rotate(const Vec3(0, 0, -1));
  camera.up = rotation.rotate(const Vec3(0, 1, 0));
}

Quat _slerp(Quat a, Quat b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (dot < 0) {
    b = Quat(-b.x, -b.y, -b.z, -b.w);
    dot = -dot;
  }
  double x, y;
  if (dot > .9995) {
    x = 1 - t;
    y = t;
  } else {
    final angle = math.acos(dot.clamp(-1, 1));
    x = math.sin((1 - t) * angle) / math.sin(angle);
    y = math.sin(t * angle) / math.sin(angle);
  }
  return Quat(
    a.x * x + b.x * y,
    a.y * x + b.y * y,
    a.z * x + b.z * y,
    a.w * x + b.w * y,
  ).normalized();
}
