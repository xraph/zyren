import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'physics.dart';

const physicsWorldService = ServiceKey<PhysicsWorld>('zyren.physics.world');
final _owners = Expando<PhysicsPlugin>('physics transform owner');

/// Fixed-step native simulation. You own [world] and close it after detaching.
final class PhysicsPlugin extends ScenePlugin {
  final PhysicsWorld world;
  final int maxCatchUpSteps;
  final double maxFrameDelta;
  final bool interpolate;
  bool debug;
  final void Function(List<PhysicsEvent>)? onEvents;
  final Map<Object3D, _Binding> _bindings = {};
  PluginContext? _context;
  Registration? _demand;
  bool _paused = false;
  double _accumulator = 0;
  double droppedSeconds = 0;
  Map<int, PhysicsPose> _previous = {}, _current = {};
  Group? _debugRoot;
  PhysicsPlugin({
    required this.world,
    this.maxCatchUpSteps = 8,
    this.maxFrameDelta = .25,
    this.interpolate = true,
    this.debug = false,
    this.onEvents,
  }) {
    if (maxCatchUpSteps < 1 || maxCatchUpSteps > 64) {
      throw RangeError.range(maxCatchUpSteps, 1, 64, 'maxCatchUpSteps');
    }
    if (!maxFrameDelta.isFinite || maxFrameDelta <= 0 || maxFrameDelta > 1) {
      throw ArgumentError('Frame delta must be in (0,1].');
    }
  }
  @override
  String get id => 'zyren.physics';
  bool get paused => _paused;
  set paused(bool value) {
    _paused = value;
    _accumulator = 0;
    if (value) {
      _demand?.dispose();
      _demand = null;
    } else if (_context case final context?) {
      _demand ??= context.acquireFrameDemand();
      context.invalidate();
    }
  }

  /// Simulated bodies own their object transform. Use body targets or teleport.
  void bind(Object3D object, PhysicsBody body) {
    if (!identical(body.world, world)) {
      throw ArgumentError('Body belongs to another world.');
    }
    body.state;
    if (_owners[object] != null || _bindings.containsKey(object)) {
      throw StateError('Object already has a physics owner.');
    }
    final binding = _Binding(object, body);
    if (_context case final context?) binding.checkScene(context.scene);
    _bindings[object] = binding;
    _owners[object] = this;
    final pose = body.state.pose;
    _previous[body.id] = pose;
    _current[body.id] = pose;
    binding.write(pose);
  }

  void unbind(Object3D object) {
    _bindings.remove(object);
    if (identical(_owners[object], this)) _owners[object] = null;
  }

  /// Call after restoring the world, then bind reacquired bodies.
  void clearBindings() {
    for (final object in _bindings.keys.toList()) {
      unbind(object);
    }
    _previous.clear();
    _current.clear();
    _accumulator = 0;
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('Physics plugin is already attached.');
    }
    if (world.isClosed) {
      throw StateError('Cannot attach a closed physics world.');
    }
    for (final binding in _bindings.values) {
      binding.checkScene(context.scene);
      binding.check();
      final owner = _owners[binding.object];
      if (owner != null && !identical(owner, this)) {
        throw StateError('Object has another physics owner.');
      }
    }
    for (final binding in _bindings.values) {
      _owners[binding.object] = this;
    }
    context.provide(physicsWorldService, world);
    _context = context;
    if (!paused) _demand = context.acquireFrameDemand();
  }

  /// Advance with seconds. Events are delivered after native stepping and poses.
  void advance(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      throw ArgumentError('Delta must be finite and nonnegative.');
    }
    if (paused) return;
    for (final b in _bindings.values) {
      b.check();
      if (!b.body.isAlive) throw StateError('Bound body handle is stale.');
      final owner = _owners[b.object];
      if (owner != null && !identical(owner, this)) {
        throw StateError('Object has another physics owner.');
      }
    }
    final states = {for (final state in world.states) state.id: state.pose};
    for (final entry in states.entries) {
      final current = _current[entry.key];
      if (current == null ||
          current.position != entry.value.position ||
          current.rotation != entry.value.rotation) {
        _previous[entry.key] = entry.value;
        _current[entry.key] = entry.value;
      }
    }
    droppedSeconds += math.max(0, seconds - maxFrameDelta);
    _accumulator += math.min(seconds, maxFrameDelta);
    final events = <PhysicsEvent>[];
    var steps = 0;
    while (_accumulator + 1e-12 >= world.fixedStep && steps < maxCatchUpSteps) {
      final result = world.step();
      _previous = _current;
      _current = {for (final b in result.bodies) b.id: b.pose};
      events.addAll(result.events);
      _accumulator -= world.fixedStep;
      steps++;
    }
    if (_accumulator >= world.fixedStep) {
      final remainder = _accumulator % world.fixedStep;
      droppedSeconds += _accumulator - remainder;
      _accumulator = remainder;
    }
    final alpha = (_accumulator / world.fixedStep).clamp(0.0, 1.0);
    for (final binding in _bindings.values) {
      final current = _current[binding.body.id];
      if (current == null) throw StateError('Bound physics body was removed.');
      final previous = _previous[binding.body.id] ?? current;
      binding.write(
        interpolate ? previous.interpolate(current, alpha) : current,
      );
    }
    if (events.isNotEmpty) onEvents?.call(List.unmodifiable(events));
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    advance(frame.delta.inMicroseconds / Duration.microsecondsPerSecond);
    if (debug) {
      if (!context.capabilities.features.contains(
        RenderFeature.portablePrimitives,
      )) {
        throw UnsupportedError(
          'Physics debug rendering requires native line primitives.',
        );
      }
      _drawDebug(context.scene);
    } else {
      _removeDebug();
    }
  }

  void _removeDebug() {
    final root = _debugRoot;
    if (root != null) root.parent?.remove(root);
    _debugRoot = null;
  }

  void _drawDebug(Scene scene) {
    _removeDebug();
    final lines = world.debugLines();
    if (lines.isEmpty) return;
    final root = Group(name: 'Physics debug');
    scene.add(root);
    _debugRoot = root;
    final groups = <String, List<DebugLine>>{};
    for (final line in lines) {
      groups.putIfAbsent(line.color.join(','), () => []).add(line);
    }
    for (final group in groups.values) {
      root.add(
        Line(
          LineGeometry.segments(
            points: [
              for (final line in group) ...[line.a, line.b],
            ],
          ),
          LineMaterial(color: _debugColor(group.first.color), width: 1),
        ),
      );
    }
  }

  @override
  void detach(PluginContext context) {
    if (!identical(_context, context)) return;
    for (final binding in _bindings.values) {
      if (identical(_owners[binding.object], this)) {
        _owners[binding.object] = null;
      }
    }
    _demand?.dispose();
    _demand = null;
    _removeDebug();
    _context = null;
    _accumulator = 0;
  }
}

final class _Binding {
  final Object3D object;
  final PhysicsBody body;
  final List<(Object3D, Vec3, Quat)> parents = [];
  late Vec3 _lastPosition;
  late Quat _lastRotation;
  _Binding(this.object, this.body) {
    _lastPosition = object.position;
    _lastRotation = object.quaternion;
    for (var parent = object.parent; parent != null; parent = parent.parent) {
      parents.add((parent, parent.position, parent.quaternion));
    }
    check();
  }
  void checkScene(Scene scene) {
    if (object != scene && !parents.any((p) => identical(p.$1, scene))) {
      throw StateError('Bound object is outside the attached scene.');
    }
  }

  void check() {
    if (object.scale != Vec3.one) {
      throw UnsupportedError(
        'Physics binding requires unit scale. Build the collider at its intended size.',
      );
    }
    if (object.position != _lastPosition ||
        object.quaternion != _lastRotation) {
      throw StateError(
        'External transform write conflicts with physics. Unbind before tools or timeline take ownership.',
      );
    }
    var parent = object.parent;
    for (final p in parents) {
      if (!identical(parent, p.$1)) {
        throw StateError('Reparenting requires unbind and bind.');
      }
      if (parent!.scale != Vec3.one ||
          parent.position != p.$2 ||
          parent.quaternion != p.$3) {
        throw StateError('Physics parents must keep a fixed rigid transform.');
      }
      parent = parent.parent;
    }
    if (parent != null) {
      throw StateError('Reparenting requires unbind and bind.');
    }
  }

  void write(PhysicsPose pose) {
    var position = pose.position;
    var rotation = pose.rotation;
    for (final parent in parents.reversed) {
      final q = parent.$3;
      final inverse = Quat(-q.x, -q.y, -q.z, q.w);
      position = inverse.rotate(position - parent.$2);
      rotation = inverse * rotation;
    }
    object.position = position;
    object.quaternion = rotation;
    _lastPosition = object.position;
    _lastRotation = object.quaternion;
  }
}

Color3 _debugColor(List<double> hsla) {
  final hue = hsla[0] / 60, saturation = hsla[1], lightness = hsla[2];
  final chroma = (1 - (2 * lightness - 1).abs()) * saturation;
  final x = chroma * (1 - (hue % 2 - 1).abs()), m = lightness - chroma / 2;
  final rgb = switch (hue.floor() % 6) {
    0 => (chroma, x, 0.0),
    1 => (x, chroma, 0.0),
    2 => (0.0, chroma, x),
    3 => (0.0, x, chroma),
    4 => (x, 0.0, chroma),
    _ => (chroma, 0.0, x),
  };
  return Color3(rgb.$1 + m, rgb.$2 + m, rgb.$3 + m);
}
