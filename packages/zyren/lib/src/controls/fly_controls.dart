part of 'orbit_navigation.dart';

/// Free flight in camera-local axes. Feed keyboard/gamepad state through
/// setMovement/setRotation; pointer drags look around and the wheel moves.
final class FlyControls extends ScenePlugin {
  @override
  String get id => 'zyren.fly';
  final double movementSpeed, rotationSpeed;
  bool _enabled;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) stop();
    _syncGestures();
  }

  PluginContext? _context;
  Camera? _camera;
  _ViewState? _last, _saved;
  Registration? _demand, _subscription;
  final _gestures = <Registration>[];
  Vec3 _movement = Vec3.zero, _angular = Vec3.zero;
  bool _fresh = false, _dragging = false;
  FlyControls({
    this.movementSpeed = 1,
    this.rotationSpeed = 1,
    bool enabled = true,
  }) : _enabled = enabled {
    if ([
      movementSpeed,
      rotationSpeed,
    ].any((v) => !v.isFinite || v < 0 || v > 1e12)) {
      throw ArgumentError('Flight speeds must be finite and in [0, 1e12].');
    }
  }
  bool get isMoving => _movement != Vec3.zero || _angular != Vec3.zero;
  bool get isInteracting => _dragging;
  Camera _current() {
    final context = _context;
    if (context == null) {
      throw StateError('Attach FlyControls before changing its camera.');
    }
    final camera = context.camera;
    if (camera is! PerspectiveCamera && camera is! OrthographicCamera) {
      throw UnsupportedError('FlyControls needs a built-in camera.');
    }
    if (!identical(camera, _camera)) {
      stop();
      camera.viewProjection(1);
      _camera = camera;
      _last = _saved = _ViewState(camera);
    } else if (_last?.matches(camera) == false) {
      stop();
      camera.viewProjection(1);
      _last = _ViewState(camera);
    }
    return camera;
  }

  /// Signed axis inputs in [-1,1]. Diagonal movement is normalized to unit speed.
  void setMovement({double right = 0, double up = 0, double forward = 0}) {
    _validateAxes(right, up, forward);
    _current();
    if (!enabled) return;
    final value = Vec3(right, up, forward);
    _movement = value.length2 > 1 ? value.normalized() : value;
    _syncDemand();
  }

  /// Signed local angular inputs in [-1,1], scaled in radians per second.
  void setRotation({double pitch = 0, double yaw = 0, double roll = 0}) {
    _validateAxes(pitch, yaw, roll);
    _current();
    if (!enabled) return;
    _angular = Vec3(pitch, yaw, roll);
    _syncDemand();
  }

  static void _validateAxes(double a, double b, double c) {
    if ([a, b, c].any((v) => !v.isFinite || v.abs() > 1)) {
      throw ArgumentError('Axis values must be in [-1,1].');
    }
  }

  /// Immediate camera-local displacement: X right, Y up, Z forward.
  void moveBy(Vec3 offset) {
    if (!offset.isFinite) {
      throw ArgumentError('Flight displacement must be finite.');
    }
    _current();
    if (!enabled) return;
    _integrate(offset, Vec3.zero, 1);
    _context!.invalidate();
  }

  /// Immediate local angular displacement in radians.
  void lookBy({double pitch = 0, double yaw = 0, double roll = 0}) {
    if ([pitch, yaw, roll].any((v) => !v.isFinite)) {
      throw ArgumentError('Look angles must be finite.');
    }
    _current();
    if (!enabled) return;
    _integrate(Vec3.zero, Vec3(pitch, yaw, roll), 1);
    _context!.invalidate();
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

  void stop() {
    _movement = _angular = Vec3.zero;
    _dragging = false;
    _fresh = false;
    _demand?.dispose();
    _demand = null;
  }

  void _syncDemand() {
    if (enabled && isMoving) {
      if (_demand == null) {
        _fresh = true;
        _demand = _context!.acquireFrameDemand();
      }
      _context!.invalidate();
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
      throw StateError('Use separate FlyControls for each view.');
    }
    if (context.input != null && context.input is! ViewportInputSource) {
      throw ArgumentError('Fly input needs viewport dimensions.');
    }
    _context = context;
    _current();
    _syncGestures();
    if (context.input case final input?) {
      _subscription = context.scope.listen(input.events, (event) {
        if (identical(context, _context)) _input(event);
      });
    }
  }

  void _input(ScenePointerEvent event) {
    if (!enabled) return;
    _current();
    if (event.phase == ScenePointerPhase.cancel) {
      stop();
      return;
    }
    if (event.phase == ScenePointerPhase.scaleEnd) {
      _dragging = false;
      return;
    }
    final input = _context!.input as ViewportInputSource;
    if (!input.logicalHeight.isFinite ||
        !input.logicalWidth.isFinite ||
        input.logicalHeight <= 0 ||
        input.logicalWidth <= 0) {
      stop();
      return;
    }
    if (event.phase == ScenePointerPhase.scaleStart) {
      _dragging = true;
      return;
    }
    if (!event.delta.x.isFinite || !event.delta.y.isFinite) return;
    if (event.phase == ScenePointerPhase.scaleUpdate && _dragging) {
      lookBy(
        yaw: -event.delta.x / input.logicalHeight * math.pi * rotationSpeed,
        pitch: -event.delta.y / input.logicalHeight * math.pi * rotationSpeed,
      );
    } else if (event.phase == ScenePointerPhase.scroll) {
      moveBy(Vec3(0, 0, -event.delta.y * .01 * movementSpeed));
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _current();
    if (!enabled || !isMoving) return;
    final seconds = _fresh
        ? 0.0
        : frame.delta.inMicroseconds.clamp(0, 100000) / 1e6;
    _fresh = false;
    if (seconds > 0) {
      _integrate(_movement * movementSpeed, _angular * rotationSpeed, seconds);
    }
  }

  void _integrate(Vec3 localVelocity, Vec3 localAngular, double seconds) {
    final camera = _camera!,
        offset = camera.target - camera.position,
        distance = offset.length;
    final forward = offset / distance,
        right = forward.cross(camera.up).normalized(),
        up = right.cross(forward);
    final velocity =
        right * localVelocity.x +
        up * localVelocity.y +
        forward * localVelocity.z;
    final omega =
        right * localAngular.x + up * localAngular.y + forward * localAngular.z;
    final speed = omega.length, angle = speed * seconds;
    if (!angle.isFinite || !velocity.isFinite) {
      throw ArgumentError('Flight update overflows.');
    }
    var delta = velocity * seconds;
    var rotation = Quat.identity;
    if (speed > 0) {
      final square = angle * angle;
      final first = angle.abs() < 1e-4
          ? seconds * seconds * (.5 - square / 24)
          : (1 - math.cos(angle)) / (speed * speed);
      final second = angle.abs() < 1e-4
          ? seconds * seconds * seconds * (1 / 6 - square / 120)
          : (angle - math.sin(angle)) / (speed * speed * speed);
      delta =
          delta +
          omega.cross(velocity) * first +
          omega.cross(omega.cross(velocity)) * second;
      rotation = Quat.axisAngle(omega, angle);
    }
    final position = camera.position + delta,
        target = position + rotation.rotate(forward) * distance,
        newUp = rotation.rotate(up);
    if (!position.isFinite ||
        !target.isFinite ||
        !(target - position).length2.isFinite ||
        (target - position).length2 < 1e-20) {
      throw ArgumentError(
        'Flight update cannot represent a valid camera pose.',
      );
    }
    camera.position = position;
    camera.target = target;
    camera.up = newUp;
    _last = _ViewState(camera);
  }

  @override
  void detach(PluginContext context) {
    if (!identical(context, _context)) return;
    stop();
    _subscription?.dispose();
    _subscription = null;
    for (final registration in _gestures) {
      registration.dispose();
    }
    _gestures.clear();
    _context = null;
    _camera = null;
    _last = _saved = null;
  }
}
