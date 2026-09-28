part of 'clip.dart';

/// Applies instance-local transforms. Use as a ScenePlugin for demand-driven
/// playback, or call update with explicit elapsed steps in standalone Dart.
final class AnimationMixer extends ScenePlugin {
  static int _nextId = 0;
  @override
  final String id;
  final Map<String, Object3D> nodes;
  List<AnimationAction> _actions = [];
  Map<(String, TransformProperty), Object> _rest = {};
  PluginContext? _context;
  Registration? _demand;
  AnimationMixer({required Map<String, Object3D> nodes, String? id})
    : id = id ?? 'gpu3d.animation.${_nextId++}',
      nodes = Map.unmodifiable(nodes) {
    if (nodes.length > 32768 ||
        nodes.keys.any((key) => key.isEmpty) ||
        (Set<Object3D>.identity()..addAll(nodes.values)).length !=
            nodes.length) {
      throw ArgumentError('Use at most 32768 unique nodes with nonempty IDs.');
    }
  }
  List<AnimationAction> get actions => List.unmodifiable(_actions);
  bool get isAdvancing => _actions.any((action) => action._state.advancing);
  AnimationAction play(
    AnimationClip clip, {
    AnimationLoop loop = AnimationLoop.repeat,
    double speed = 1,
    double weight = 1,
  }) {
    AnimationAction._speed(speed);
    AnimationAction._weight(weight);
    if (_actions.length >= 256) {
      throw StateError('Stop an action before exceeding 256 actions.');
    }
    if (clip.tracks.length +
            _actions.fold<int>(
              0,
              (n, action) => n + action.clip.tracks.length,
            ) >
        32768) {
      throw StateError('A mixer supports at most 32768 active track bindings.');
    }
    for (final track in clip.tracks) {
      if (!nodes.containsKey(track.target)) {
        throw ArgumentError('Unknown animation target: ${track.target}');
      }
    }
    final action = AnimationAction._(
      this,
      clip,
      _Playback(
        phase: speed < 0 ? clip.durationSeconds : 0,
        speed: speed,
        weight: weight,
        loop: loop,
        finished: clip.durationSeconds == 0,
      ),
    );
    _apply([..._actions, action], const {}, invalidate: true);
    return action;
  }

  void stopAll() {
    final previous = _actions;
    _apply([], const {}, invalidate: true);
    for (final action in previous) {
      action._stopped = true;
    }
  }

  void update(Duration delta) => _update(delta, fromFrame: false);
  void _update(Duration delta, {required bool fromFrame}) {
    if (delta.isNegative) throw ArgumentError.value(delta, 'delta');
    final seconds = delta.inMicroseconds / 1e6;
    final states = <AnimationAction, _Playback>{};
    for (final action in _actions) {
      final next = action._state.copy(), duration = action.clip.durationSeconds;
      if (next.advancing && !(fromFrame && next.fresh) && seconds != 0) {
        final phase = next.phase + seconds * next.speed;
        if (next.loop == AnimationLoop.once) {
          next.phase = phase.clamp(0.0, duration);
          next.finished = next.speed > 0 ? phase >= duration : phase <= 0;
        } else {
          next.phase =
              phase %
              (next.loop == AnimationLoop.pingPong ? 2 * duration : duration);
        }
      }
      next.fresh = false;
      states[action] = next;
    }
    _apply(_actions, states, invalidate: !fromFrame);
  }

  void _apply(
    List<AnimationAction> actions,
    Map<AnimationAction, _Playback> states, {
    required bool invalidate,
  }) {
    final rest = Map<(String, TransformProperty), Object>.of(_rest);
    final retained = <(String, TransformProperty)>{};
    final mixed = <(String, TransformProperty), (Object, double)>{};
    for (final action in actions) {
      final state = states[action] ?? action._state;
      for (final track in action.clip.tracks) {
        final key = (track.target, track.property);
        retained.add(key);
        rest.putIfAbsent(key, () => _read(nodes[key.$1]!, key.$2));
        if (state.weight == 0) continue;
        final value = track.sample(state.time(action.clip.durationSeconds));
        final previous = mixed[key];
        mixed[key] = previous == null
            ? (value, state.weight)
            : (
                _blend(
                  previous.$1,
                  value,
                  state.weight / (previous.$2 + state.weight),
                ),
                previous.$2 + state.weight,
              );
      }
    }
    final poses = <(String, TransformProperty), Object>{};
    for (final entry in rest.entries) {
      final sample = mixed[entry.key];
      final value = sample == null
          ? entry.value
          : sample.$2 < 1
          ? _blend(sample.$1, entry.value, 1 - sample.$2)
          : sample.$1;
      _validate(entry.key.$2, value);
      poses[entry.key] = value;
    }
    // Validate every result before publishing any transform or playback state.
    for (final entry in poses.entries) {
      final node = nodes[entry.key.$1]!;
      switch (entry.key.$2) {
        case TransformProperty.position:
          node.position = entry.value as Vec3;
        case TransformProperty.rotation:
          node.quaternion = entry.value as Quat;
        case TransformProperty.scale:
          node.scale = entry.value as Vec3;
      }
    }
    _rest = {for (final key in retained) key: rest[key]!};
    _actions = List.of(actions);
    for (final entry in states.entries) {
      entry.key._state = entry.value;
    }
    _syncDemand();
    if (invalidate) _context?.invalidate();
  }

  static Object _read(Object3D node, TransformProperty property) =>
      switch (property) {
        TransformProperty.position => node.position,
        TransformProperty.rotation => node.quaternion,
        TransformProperty.scale => node.scale,
      };
  static Object _blend(Object a, Object b, double weight) => a is Quat
      ? _slerp(a, b as Quat, weight)
      : (a as Vec3) * (1 - weight) + (b as Vec3) * weight;
  static void _validate(TransformProperty property, Object value) {
    if (value is Quat) {
      value.normalized();
      return;
    }
    final v = value as Vec3;
    if (!v.isFinite ||
        (property == TransformProperty.scale &&
            (v.x == 0 || v.y == 0 || v.z == 0))) {
      throw ArgumentError(
        'Animation produced a nonfinite or singular $property value.',
      );
    }
  }

  void _syncDemand() {
    final context = _context;
    if (context != null && isAdvancing) {
      _demand ??= context.acquireFrameDemand();
    } else {
      _demand?.dispose();
      _demand = null;
    }
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('An animation mixer belongs to one attachment.');
    }
    _context = context;
    for (final action in _actions) {
      action._state.fresh = true;
    }
    context.scope.onClose(() {
      _demand?.dispose();
      _demand = null;
      _context = null;
    });
    _syncDemand();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) =>
      _update(frame.delta, fromFrame: true);
  @override
  void detach(PluginContext context) {
    _demand?.dispose();
    _demand = null;
    _context = null;
  }
}
