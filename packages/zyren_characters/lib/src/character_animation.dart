import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';

final _characterOwners = Expando<CharacterAnimationPlugin>(
  'character pose owner',
);

/// A named clip. The host owns decisions such as when to walk or idle.
final class CharacterState {
  final String id;
  final TimelineClip clip;
  final bool loop;
  CharacterState(this.id, this.clip, {this.loop = true}) {
    if (id.trim().isEmpty) throw ArgumentError('State IDs must not be empty.');
  }
  factory CharacterState.animation(
    String id,
    ModelInstance instance,
    ModelAnimation animation, {
    bool loop = true,
    ModelPose Function(ModelPose)? process,
  }) => CharacterState(
    id,
    modelClip(instance, animation, process: process),
    loop: loop,
  );
  factory CharacterState.rest(
    String id,
    ModelInstance instance, {
    ModelPose Function(ModelPose)? process,
  }) => CharacterState(
    id,
    modelRestClip(instance, process: process),
    loop: false,
  );
}

/// One allowed directed state change, with a positive crossfade duration.
final class CharacterTransition {
  final String from, to;
  final Duration duration;
  CharacterTransition(
    this.from,
    this.to, {
    this.duration = const Duration(milliseconds: 200),
  }) {
    if (from == to || duration <= Duration.zero) {
      throw ArgumentError(
        'Transitions need distinct states and positive duration.',
      );
    }
  }
}

/// Owns actions on an existing mixed timeline, without a second animation clock.
///
/// Register [timeline] in the engine too. Its base must cover every state target.
/// Keep physics on an outer group and clip targets beneath that group. Use a
/// distinct [id] for each character when sharing one timeline between characters.
final class CharacterAnimationPlugin extends ScenePlugin {
  @override
  final String id;
  final SceneTimelinePlugin timeline;
  final List<CharacterState> states;
  final List<CharacterTransition> transitions;
  final String initialState;
  final Map<String, TimelineAction> _actions = {};
  final Set<Object3D> _targets = Set.identity();
  final Map<(String, String), Duration> _edges = {};
  PluginContext? _context;
  late String _current = initialState;
  bool _paused = false;

  CharacterAnimationPlugin({
    required this.timeline,
    required Iterable<CharacterState> states,
    required Iterable<CharacterTransition> transitions,
    required this.initialState,
    this.id = 'zyren.characters',
  }) : states = List.unmodifiable(states),
       transitions = List.unmodifiable(transitions) {
    final ids = this.states.map((s) => s.id).toSet();
    if (id.trim().isEmpty ||
        ids.length != this.states.length ||
        !ids.contains(initialState)) {
      throw ArgumentError('Use unique states and an existing initial state.');
    }
    for (final edge in this.transitions) {
      if (!ids.contains(edge.from) ||
          !ids.contains(edge.to) ||
          _edges.containsKey((edge.from, edge.to))) {
        throw ArgumentError(
          'Transitions must be unique and reference existing states.',
        );
      }
      _edges[(edge.from, edge.to)] = edge.duration;
    }
  }

  @override
  Set<String> get dependencies => {timeline.id};
  String get currentState => _current;
  bool get isPaused => _paused;
  bool get isAttached => _context != null;
  Map<String, double> get weights => Map.unmodifiable({
    for (final e in _actions.entries) e.key: e.value.weight,
  });
  Map<String, ({Duration position, Duration traversal, double weight})>
  get clocks {
    _check();
    return Map.unmodifiable({
      for (final e in _actions.entries)
        e.key: (
          position: e.value.position,
          traversal: e.value.traversal,
          weight: e.value.weight,
        ),
    });
  }

  /// Saves all independent action clocks, including interrupted transitions.
  Map<String, Object?> captureState() {
    _check();
    return Map.unmodifiable({
      'version': 1,
      'current': _current,
      'paused': _paused,
      'actions': Map<String, Object?>.unmodifiable({
        for (final e in _actions.entries) e.key: e.value.captureState(),
      }),
    });
  }

  void validateState(Map<String, Object?> state) {
    _check();
    final actions = state['actions'];
    if (state.length != 4 ||
        state['version'] != 1 ||
        !_actions.containsKey(state['current']) ||
        state['paused'] is! bool ||
        actions is! Map<String, Object?> ||
        actions.length != _actions.length ||
        !actions.keys.toSet().containsAll(_actions.keys)) {
      throw const FormatException('Invalid character animation checkpoint.');
    }
    for (final entry in _actions.entries) {
      final action = actions[entry.key];
      if (action is! Map<String, Object?>) {
        throw const FormatException('Invalid character action checkpoint.');
      }
      entry.value.validateState(action);
    }
  }

  void restoreState(Map<String, Object?> state) {
    validateState(state);
    final actions = state['actions'] as Map<String, Object?>;
    timeline.restoreActionStates({
      for (final e in _actions.entries)
        e.value: actions[e.key] as Map<String, Object?>,
    });
    _current = state['current'] as String;
    _paused = state['paused'] as bool;
  }

  Duration positionOf(String state) {
    _check();
    return (_actions[state] ?? (throw ArgumentError.value(state, 'state')))
        .position;
  }

  void _check() {
    if (_context == null) {
      throw StateError('Attach the character before playback.');
    }
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) throw StateError('Character is already attached.');
    if (!identical(context.service(timeline.serviceKey), timeline)) {
      throw StateError('Character requires its registered timeline.');
    }
    final targets = {
      for (final state in states) ...state.clip.tracks.map((t) => t.target),
    };
    if (targets.any((target) => _characterOwners[target] != null)) {
      throw StateError('An animation target already has a character owner.');
    }
    _targets.addAll(targets);
    for (final target in targets) {
      _characterOwners[target] = this;
    }
    _context = context;
    _current = initialState;
    _paused = false;
    for (final state in states) {
      _actions[state.id] = timeline.createAction(state.clip, loop: state.loop);
    }
    _actions[_current]!.fadeTo(1, Duration.zero);
    _actions[_current]!.play();
  }

  /// Returns false for a same-state request. Missing edges leave playback intact.
  /// The destination resumes its clock, including during an interrupted fade.
  bool transitionTo(String state) {
    _check();
    if (_paused) {
      throw StateError('Resume the character before changing state.');
    }
    if (state == _current) return false;
    final duration = _edges[(_current, state)];
    if (duration == null) {
      throw StateError('Transition $_current -> $state is not allowed.');
    }
    final destination = _actions[state]!;
    destination.play();
    for (final entry in _actions.entries) {
      entry.value.fadeTo(entry.key == state ? 1 : 0, duration);
    }
    _current = state;
    return true;
  }

  /// Freezes clip clocks and settles a fade at its current weights.
  void pause() {
    _check();
    for (final action in _actions.values) {
      action.pause();
      action.fadeTo(action.weight, Duration.zero);
    }
    _paused = true;
  }

  /// Resumes the selected clip and completes any interrupted transition.
  void resume({Duration fadeDuration = const Duration(milliseconds: 200)}) {
    _check();
    if (fadeDuration <= Duration.zero) {
      throw ArgumentError('Resume fade must be positive.');
    }
    if (!_paused) return;
    _actions[_current]!.play();
    for (final entry in _actions.entries) {
      entry.value.fadeTo(entry.key == _current ? 1 : 0, fadeDuration);
      if (entry.value.weight > 0 && entry.key != _current) entry.value.play();
    }
    _paused = false;
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    for (final entry in _actions.entries) {
      if (entry.key != _current &&
          entry.value.weight == 0 &&
          entry.value.isPlaying) {
        entry.value.pause();
      }
    }
  }

  @override
  void detach(PluginContext context) {
    if (!identical(_context, context)) return;
    try {
      for (final action in _actions.values.toList().reversed) {
        try {
          action.dispose();
        } on StateError {
          // Removed targets cannot sample a rest pose. The owning timeline
          // invalidates its remaining handles when it detaches next.
        }
      }
    } finally {
      _actions.clear();
      for (final target in _targets) {
        if (identical(_characterOwners[target], this)) {
          _characterOwners[target] = null;
        }
      }
      _targets.clear();
      _context = null;
      _paused = false;
    }
  }
}
