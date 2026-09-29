import 'dart:math' as math;
import '../input/pointer_event.dart';
import '../math/vec3.dart';
import '../math/vec2.dart';
import '../math/quat.dart';
import '../plugins/engine.dart';
import '../plugins/registration.dart';
import '../scene/scene.dart';
part 'trackball_controls.dart';
part 'fly_controls.dart';

/// Limits use scene units, radians and orthographic zoom factors.
final class OrbitLimits {
  final double minDistance, maxDistance, minZoom, maxZoom;
  final double minPolarAngle, maxPolarAngle;
  OrbitLimits({
    this.minDistance = .01,
    this.maxDistance = double.infinity,
    this.minZoom = .01,
    this.maxZoom = 1000,
    this.minPolarAngle = 1e-6,
    this.maxPolarAngle = math.pi - 1e-6,
  }) {
    if (!minDistance.isFinite ||
        minDistance <= 0 ||
        maxDistance.isNaN ||
        maxDistance < minDistance ||
        !minZoom.isFinite ||
        minZoom <= 0 ||
        !maxZoom.isFinite ||
        maxZoom < minZoom ||
        !minPolarAngle.isFinite ||
        !maxPolarAngle.isFinite ||
        minPolarAngle <= 0 ||
        maxPolarAngle >= math.pi ||
        minPolarAngle > maxPolarAngle) {
      throw ArgumentError(
        'Orbit limits require ordered positive ranges and polar angles inside (0, pi).',
      );
    }
  }
}

enum OrbitDragAction { rotate, pan, zoom, none }

typedef OrbitDragBinding = OrbitDragAction Function(ScenePointerEvent event);

/// Per-view camera controls using the host's won gestures and frame demand.
class OrbitControls extends ScenePlugin {
  @override
  String get id => 'zyren.orbit';
  final OrbitLimits limits;
  final Duration damping;
  final double rotateSpeed, panSpeed, zoomSpeed;
  final OrbitDragBinding dragBinding;
  bool _enabled;
  PluginContext? _context;
  Camera? _camera;
  _ViewState? _saved, _last;
  Registration? _demand, _subscription;
  final _gestures = <Registration>[];
  bool _dragging = false, _freshDelta = false;
  double _azimuth = 0, _polar = 0, _logZoom = 0, _lastScale = 1;
  Vec3 _pan = Vec3.zero;

  OrbitControls({
    bool enabled = true,
    OrbitLimits? limits,
    this.damping = const Duration(milliseconds: 80),
    this.rotateSpeed = 1,
    this.panSpeed = 1,
    this.zoomSpeed = 1,
    OrbitDragBinding? dragBinding,
  }) : _enabled = enabled,
       limits = limits ?? OrbitLimits(),
       dragBinding = dragBinding ?? defaultDragBinding {
    if (damping.isNegative ||
        [rotateSpeed, panSpeed, zoomSpeed].any((v) => !v.isFinite || v < 0)) {
      throw ArgumentError(
        'Damping and input speeds must be finite and nonnegative.',
      );
    }
  }

  /// One finger/primary drag orbits; two fingers, secondary or Shift drag pan.
  /// Middle drag dollies. Pinch and wheel zoom independently of this binding.
  static OrbitDragAction defaultDragBinding(ScenePointerEvent event) {
    if (event.pointerCount >= 2 ||
        event.kind == ScenePointerKind.trackpad ||
        event.buttons & 2 != 0 ||
        event.modifiers.contains(SceneModifier.shift)) {
      return OrbitDragAction.pan;
    }
    if (event.buttons & 4 != 0) return OrbitDragAction.zoom;
    return OrbitDragAction.rotate;
  }

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) stop();
    _syncGestures();
  }

  bool get isInteracting => _dragging;
  bool get isSettling => _hasMotion;
  bool get _hasMotion =>
      _azimuth != 0 || _polar != 0 || _logZoom != 0 || _pan != Vec3.zero;

  Camera _current() {
    final context = _context;
    if (context == null) {
      throw StateError('Attach OrbitControls before changing its camera.');
    }
    final camera = context.camera;
    if (camera is! PerspectiveCamera && camera is! OrthographicCamera) {
      throw UnsupportedError(
        'OrbitControls requires a built-in camera projection.',
      );
    }
    if (!identical(camera, _camera)) {
      stop();
      camera.viewProjection(1);
      _camera = camera;
      _saved = _last = _ViewState(camera);
    } else if (_last?.matches(camera) == false) {
      stop();
      camera.viewProjection(1);
      _last = _ViewState(camera);
    }
    return camera;
  }

  /// Positive azimuth rotates about camera.up; polar increases toward -up.
  void rotateBy({double azimuth = 0, double polar = 0}) {
    if (!azimuth.isFinite || !polar.isFinite) {
      throw ArgumentError('Orbit angles must be finite.');
    }
    _current();
    if (!enabled) return;
    final a = _azimuth + azimuth, p = _polar + polar;
    if (!a.isFinite || !p.isFinite) {
      throw ArgumentError('Accumulated orbit angles overflow.');
    }
    _azimuth = a;
    _polar = p;
    _changed();
  }

  /// Translates both camera and target by a world-space offset.
  void panBy(Vec3 offset) {
    if (!offset.isFinite) throw ArgumentError('Pan offset must be finite.');
    final camera = _current();
    if (!enabled) return;
    final next = _pan + offset;
    if (!next.isFinite ||
        !(camera.position + next).isFinite ||
        !(camera.target + next).isFinite) {
      throw ArgumentError('Accumulated pan exceeds finite coordinates.');
    }
    _pan = next;
    _changed();
  }

  /// Factors above one move away or reduce orthographic zoom.
  void zoomBy(double factor) {
    if (!factor.isFinite || factor <= 0) {
      throw ArgumentError.value(factor, 'factor');
    }
    _current();
    if (!enabled) return;
    _logZoom = (_logZoom + math.log(factor)).clamp(-700, 700);
    _changed();
  }

  /// Discards pending movement and releases continuous frame demand.
  void stop() {
    _azimuth = _polar = _logZoom = 0;
    _pan = Vec3.zero;
    _dragging = false;
    _lastScale = 1;
    _demand?.dispose();
    _demand = null;
    _freshDelta = false;
  }

  void saveState() {
    _saved = _ViewState(_current());
  }

  void reset() {
    final camera = _current();
    stop();
    _saved!.apply(camera);
    _last = _ViewState(camera);
    _context!.invalidate();
  }

  void _changed() {
    if (!_hasMotion) return;
    if (damping == Duration.zero) _step(1);
    _syncDemand();
    _context!.invalidate();
  }

  void _syncDemand() {
    if (enabled && (_dragging || _hasMotion)) {
      if (_demand == null) {
        _freshDelta = true;
        _demand = _context!.acquireFrameDemand();
      }
    } else {
      _demand?.dispose();
      _demand = null;
    }
  }

  void _syncGestures() {
    for (final registration in _gestures) {
      registration.dispose();
    }
    _gestures.clear();
    final context = _context, input = _context?.input;
    if (!enabled || context == null || input == null) return;
    for (final gesture in [SceneGesture.scale, SceneGesture.scroll]) {
      _gestures.add(context.scope.keep(input.registerGesture(gesture)));
    }
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('Use a separate OrbitControls for each view.');
    }
    if (context.input != null && context.input is! ViewportInputSource) {
      throw ArgumentError(
        'Orbit gesture input must provide logical viewport dimensions.',
      );
    }
    _context = context;
    _current();
    _syncGestures();
    if (context.input case final input?) {
      _subscription = context.scope.listen(input.events, (event) {
        if (identical(_context, context)) _input(event);
      });
    }
  }

  void _input(ScenePointerEvent event) {
    if (!enabled) return;
    final camera = _current();
    if (event.phase == ScenePointerPhase.cancel) {
      stop();
      return;
    }
    if (event.phase == ScenePointerPhase.scaleEnd) {
      _dragging = false;
      _syncDemand();
      return;
    }
    final input = _context!.input as ViewportInputSource;
    final width = input.logicalWidth, height = input.logicalHeight;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      stop();
      return;
    }
    if (event.phase == ScenePointerPhase.scaleStart) {
      _dragging = true;
      _lastScale = 1;
      _syncDemand();
      return;
    }
    if (!event.delta.x.isFinite || !event.delta.y.isFinite) return;
    if (event.phase == ScenePointerPhase.scroll) {
      zoomBy(math.exp((event.delta.y * zoomSpeed * .001).clamp(-20, 20)));
    } else if (event.phase == ScenePointerPhase.scaleUpdate && _dragging) {
      switch (dragBinding(event)) {
        case OrbitDragAction.rotate:
          _rotatePointer(event, width, height);
        case OrbitDragAction.pan:
          final z = (camera.position - camera.target).normalized();
          final x = camera.up.cross(z).normalized(), y = z.cross(x);
          final span = switch (camera) {
            PerspectiveCamera(:final fieldOfView) =>
              2 *
                  camera.position.distanceTo(camera.target) *
                  math.tan(fieldOfView / 2),
            OrthographicCamera(:final verticalSize, :final zoom) =>
              verticalSize / zoom,
            _ => throw StateError('Unsupported orbit camera.'),
          };
          panBy(
            (x * (-event.delta.x) + y * event.delta.y) *
                (span / height * panSpeed),
          );
        case OrbitDragAction.zoom:
          zoomBy(math.exp((event.delta.y * zoomSpeed * .01).clamp(-20, 20)));
        case OrbitDragAction.none:
          break;
      }
      if (event.scale.isFinite && event.scale > 0) {
        final delta = math.log(_lastScale) - math.log(event.scale);
        if (delta != 0) zoomBy(math.exp((delta * zoomSpeed).clamp(-20, 20)));
        _lastScale = event.scale;
      }
    }
  }

  void _rotatePointer(ScenePointerEvent event, double width, double height) {
    rotateBy(
      azimuth: -2 * math.pi * event.delta.x / height * rotateSpeed,
      polar: -2 * math.pi * event.delta.y / height * rotateSpeed,
    );
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _current();
    if (!enabled || !_hasMotion) return;
    final seconds = _freshDelta
        ? 0.0
        : frame.delta.inMicroseconds.clamp(0, 100000) / 1e6;
    _freshDelta = false;
    if (seconds > 0 || damping == Duration.zero) {
      _step(
        damping == Duration.zero
            ? 1
            : 1 - math.exp(-seconds / (damping.inMicroseconds / 1e6)),
      );
    }
    _syncDemand();
  }

  void _step(double fraction) {
    final camera = _camera!;
    final offset = camera.position - camera.target, radius = offset.length;
    if (_azimuth.abs() < 1e-7 &&
        _polar.abs() < 1e-7 &&
        _logZoom.abs() < 1e-7 &&
        _pan.length < math.max(1e-9, radius * 1e-7)) {
      fraction = 1;
    }
    final up = camera.up.normalized(), back = offset / radius;
    final phi = (math.acos(back.dot(up).clamp(-1, 1)) + _polar * fraction)
        .clamp(limits.minPolarAngle, limits.maxPolarAngle);
    final horizontal = (back - up * back.dot(up)).normalized();
    final theta = _azimuth * fraction;
    final direction =
        (horizontal * math.cos(theta) +
                up.cross(horizontal) * math.sin(theta)) *
            math.sin(phi) +
        up * math.cos(phi);
    var distance = radius;
    double? zoom;
    if (camera is PerspectiveCamera) {
      distance = math
          .exp((math.log(radius) + _logZoom * fraction).clamp(-700, 700))
          .clamp(limits.minDistance, limits.maxDistance);
    } else if (camera is OrthographicCamera) {
      zoom = math
          .exp((math.log(camera.zoom) - _logZoom * fraction).clamp(-700, 700))
          .clamp(limits.minZoom, limits.maxZoom);
    }
    final target = camera.target + _pan * fraction;
    final position = target + direction * distance;
    if (!target.isFinite ||
        !position.isFinite ||
        !(position - target).length2.isFinite ||
        (position - target).length2 < 1e-20 ||
        !camera.up.cross(position - target).length2.isFinite ||
        camera.up.cross(position - target).length2 < 1e-20) {
      stop();
      throw ArgumentError('Orbit update cannot represent a valid camera pose.');
    }
    camera.position = position;
    camera.target = target;
    if (camera is OrthographicCamera) camera.zoom = zoom!;
    _last = _ViewState(camera);
    final remaining = 1 - fraction;
    _azimuth *= remaining;
    _polar *= remaining;
    _logZoom *= remaining;
    _pan = _pan * remaining;
  }

  @override
  void detach(PluginContext context) {
    if (!identical(_context, context)) return;
    stop();
    _subscription?.dispose();
    _subscription = null;
    for (final gesture in _gestures) {
      gesture.dispose();
    }
    _gestures.clear();
    _context = null;
    _camera = null;
    _last = _saved = null;
  }
}

class _ViewState {
  final Vec3 position, target, up;
  final double near, far;
  final double? fov, zoom, verticalSize;
  _ViewState(Camera camera)
    : position = camera.position,
      target = camera.target,
      up = camera.up,
      near = switch (camera) {
        PerspectiveCamera c => c.near,
        OrthographicCamera c => c.near,
        _ => 0,
      },
      far = switch (camera) {
        PerspectiveCamera c => c.far,
        OrthographicCamera c => c.far,
        _ => 0,
      },
      fov = camera is PerspectiveCamera ? camera.fieldOfView : null,
      zoom = camera is OrthographicCamera ? camera.zoom : null,
      verticalSize = camera is OrthographicCamera ? camera.verticalSize : null;
  bool matches(Camera camera) =>
      position == camera.position &&
      target == camera.target &&
      up == camera.up &&
      (camera is! OrthographicCamera ||
          (zoom == camera.zoom && verticalSize == camera.verticalSize)) &&
      (camera is! PerspectiveCamera || fov == camera.fieldOfView);
  void apply(Camera camera) {
    camera.position = position;
    camera.target = target;
    camera.up = up;
    switch (camera) {
      case PerspectiveCamera c:
        if (near >= c.far) c.far = far;
        c.near = near;
        c.far = far;
        c.fieldOfView = fov!;
      case OrthographicCamera c:
        if (near >= c.far) c.far = far;
        c.near = near;
        c.far = far;
        c.zoom = zoom!;
        c.verticalSize = verticalSize!;
    }
  }
}
