part of 'clip.dart';

/// Applies instance-local transforms. Use as a ScenePlugin for demand-driven
/// playback, or call update with explicit elapsed steps in standalone Dart.
final class AnimationMixer extends ScenePlugin {
  static int _nextId = 0;
  @override
  final String id;
  final Map<String, Object3D> nodes;
  final Map<String, List<Mesh>> morphTargets;
  List<AnimationAction> _actions = [];
  final _events = StreamController<AnimationEvent>.broadcast();

  /// Asynchronous events from committed playback updates. Subscribe before play
  /// to receive zero-duration completion; cancel when the owner is disposed.
  Stream<AnimationEvent> get events => _events.stream;
  Map<(String, TransformProperty), Object> _rest = {};
  PluginContext? _context;
  Registration? _demand;
  Registration? _attachment;
  AnimationSystem? _system;
  AnimationMixer({
    required Map<String, Object3D> nodes,
    Map<String, List<Mesh>> morphTargets = const {},
    String? id,
  }) : id = id ?? 'zyren.animation.${_nextId++}',
       nodes = Map.unmodifiable(nodes),
       morphTargets = _morphBindings(nodes, morphTargets) {
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
    int? repetitions,
    AnimationBlendMode blendMode = AnimationBlendMode.normal,
    Duration referenceTime = Duration.zero,
  }) {
    AnimationAction._speed(speed);
    AnimationAction._repetitions(repetitions);
    AnimationAction._weight(weight);
    final referenceSeconds = referenceTime.inMicroseconds / 1e6;
    if (referenceTime.isNegative ||
        referenceSeconds > clip.durationSeconds ||
        (blendMode == AnimationBlendMode.normal &&
            referenceTime != Duration.zero)) {
      throw ArgumentError.value(
        referenceTime,
        'referenceTime',
        'Choose a time within the clip for additive playback; normal playback uses zero.',
      );
    }
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
      if (track is MorphWeightKeyframeTrack &&
          (morphTargets[track.target] == null ||
              morphTargets[track.target]!.any(
                (mesh) => mesh.morphWeights.length != track.targetCount,
              ))) {
        throw ArgumentError(
          'Morph track width must match every bound primitive.',
        );
      }
      if (!nodes.containsKey(track.target)) {
        throw ArgumentError('Unknown animation target: ${track.target}');
      }
    }
    final reference = <KeyframeTrack, Object>{};
    if (blendMode == AnimationBlendMode.additive) {
      for (final track in clip.tracks) {
        final value = track.sample(referenceSeconds);
        _validate(track.property, value);
        reference[track] = value;
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
        repetitions: repetitions,
        finished: clip.durationSeconds == 0,
      ),
      blendMode: blendMode,
      referenceTime: referenceTime,
      referencePose: reference,
    );
    _apply([..._actions, action], const {}, invalidate: true);
    if (action.isFinished) _publishEvent(action, finished: true, delta: 0);
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
    final states = <AnimationAction, _Playback>{};
    for (final action in _actions) {
      final next = action._state.copy(), duration = action.clip.durationSeconds;
      _advanceAnimation(next, delta.inMicroseconds, duration, fromFrame);
      states[action] = next;
    }
    final events = <(AnimationAction, bool, int)>[];
    for (final entry in states.entries) {
      final before = entry.key._state, after = entry.value;
      final delta = after.completedRepetitions - before.completedRepetitions;
      if ((!before.finished && after.finished) || delta > 0) {
        events.add((entry.key, after.finished, delta));
      }
    }
    _apply(_actions, states, invalidate: !fromFrame);
    for (final (action, finished, delta) in events) {
      _publishEvent(action, finished: finished, delta: delta);
    }
  }

  void _publishEvent(
    AnimationAction action, {
    required bool finished,
    required int delta,
  }) {
    if (!_events.hasListener) return;
    _events.add(
      finished
          ? AnimationFinishedEvent._(action)
          : AnimationLoopEvent._(action, delta),
    );
  }

  void _apply(
    List<AnimationAction> actions,
    Map<AnimationAction, _Playback> states, {
    required bool invalidate,
  }) {
    final rest = Map<(String, TransformProperty), Object>.of(_rest);
    final retained = <(String, TransformProperty)>{};
    final mixed = <(String, TransformProperty), (Object, double)>{};
    final additive = <(String, TransformProperty), Object>{};
    for (final action in actions) {
      final state = states[action] ?? action._state;
      for (final track in action.clip.tracks) {
        final key = (track.target, track.property);
        retained.add(key);
        rest.putIfAbsent(key, () => _read(key.$1, key.$2));
        if (state.weight == 0) continue;
        final value = track.sample(state.time(action.clip.durationSeconds));
        if (action.blendMode == AnimationBlendMode.additive) {
          final offset = _animationOffset(value, action._referencePose[track]!);
          additive[key] = _addAnimationValue(
            additive[key] ?? _animationIdentity(offset),
            offset,
            state.weight,
          );
          continue;
        }
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
      Object blendRest(Object rest) {
        final base = sample == null
            ? rest
            : sample.$2 < 1
            ? _blend(sample.$1, rest, 1 - sample.$2)
            : sample.$1;
        final offset = additive[entry.key];
        return offset == null ? base : _addAnimationValue(base, offset, 1);
      }

      if (entry.value is Map<Mesh, List<double>>) {
        final weights = <Mesh, List<double>>{};
        for (final rest in (entry.value as Map<Mesh, List<double>>).entries) {
          final value = blendRest(rest.value) as List<double>;
          _validate(entry.key.$2, value);
          weights[rest.key] = value;
        }
        poses[entry.key] = weights;
      } else {
        final value = blendRest(entry.value);
        _validate(entry.key.$2, value);
        poses[entry.key] = value;
      }
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
        case TransformProperty.morphWeights:
          for (final pose in (entry.value as Map<Mesh, List<double>>).entries) {
            pose.key.morphWeights = pose.value;
          }
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

  Object _read(String target, TransformProperty property) => switch (property) {
    TransformProperty.position => nodes[target]!.position,
    TransformProperty.rotation => nodes[target]!.quaternion,
    TransformProperty.scale => nodes[target]!.scale,
    TransformProperty.morphWeights => <Mesh, List<double>>{
      for (final mesh in morphTargets[target]!) mesh: mesh.morphWeights,
    },
  };
  static Object _blend(Object a, Object b, double weight) => a is Quat
      ? _slerp(a, b as Quat, weight)
      : a is List<double>
      ? List<double>.unmodifiable([
          for (var i = 0; i < a.length; i++)
            a[i] * (1 - weight) + (b as List<double>)[i] * weight,
        ])
      : (a as Vec3) * (1 - weight) + (b as Vec3) * weight;
  static void _validate(TransformProperty property, Object value) {
    if (value is List<double>) {
      if (value.any((v) => !v.isFinite || v.abs() > 1e6)) {
        throw ArgumentError('Animation produced invalid morph weights.');
      }
      return;
    }
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
    if (_system != null) {
      throw StateError(
        'Register the owning AnimationSystem instead of its mixer.',
      );
    }
    _attachContext(context);
  }

  void _attachContext(PluginContext context) {
    if (_context != null) {
      throw StateError('An animation mixer belongs to one attachment.');
    }
    _context = context;
    for (final action in _actions) {
      action._state.fresh = true;
      action._state.fade = action._state.fade?.reattach();
      action._state.warp = action._state.warp?.reattach();
    }
    _attachment = context.scope.onClose(() {
      _demand?.dispose();
      _demand = null;
      _context = null;
      _attachment = null;
    });
    _syncDemand();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) =>
      _update(frame.delta, fromFrame: true);
  @override
  void detach(PluginContext context) {
    if (identical(_context, context)) _attachment?.dispose();
  }
}

Map<String, List<Mesh>> _morphBindings(
  Map<String, Object3D> nodes,
  Map<String, List<Mesh>> explicit,
) {
  final bindings = <String, List<Mesh>>{
    for (final entry in nodes.entries)
      if (entry.value is Mesh && (entry.value as Mesh).morphWeights.isNotEmpty)
        entry.key: [entry.value as Mesh],
    ...explicit,
  };
  final seen = Set<Mesh>.identity();
  for (final entry in bindings.entries) {
    if (!nodes.containsKey(entry.key) ||
        entry.value.isEmpty ||
        entry.value.length > 32768 ||
        entry.value.any(
          (mesh) => mesh.morphWeights.isEmpty || !seen.add(mesh),
        ) ||
        seen.length > 32768) {
      throw ArgumentError(
        'Morph bindings require known node IDs and distinct morph meshes, up to 32768 primitives.',
      );
    }
  }
  return Map.unmodifiable({
    for (final entry in bindings.entries)
      entry.key: List<Mesh>.unmodifiable(entry.value),
  });
}
