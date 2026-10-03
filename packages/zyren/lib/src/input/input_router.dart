import 'dart:async';
import '../plugins/registration.dart';
import 'pointer_event.dart';

/// Higher priorities claim first. Equal priorities use stable consumer IDs.
abstract final class InputPriority {
  static const navigation = 100, objects = 200, tools = 300;
}

/// One deterministic pointer owner per input source, before consumer callbacks.
/// Use this for consumers which change scene or camera state. The source's raw
/// broadcast stream remains available for passive observation.
final class InputRouter {
  static final _routers = Expando<InputRouter>();
  static InputRouter forSource(InputSource source) =>
      _routers[source] ??= InputRouter._(source);
  final InputSource _source;
  final _consumers = <String, _Consumer>{};
  final _owners = <int, _Consumer>{};
  final _pointers = <int, ScenePointerEvent>{};
  StreamSubscription<ScenePointerEvent>? _subscription;
  int _blocks = 0;
  InputRouter._(this._source);

  bool get blocked => _blocks > 0;
  Map<int, String> get owners => Map.unmodifiable(
    _owners.map((pointer, owner) => MapEntry(pointer, owner.id)),
  );

  Registration register({
    required String id,
    required int priority,
    required bool Function(ScenePointerEvent) claims,
    required void Function(ScenePointerEvent) onEvent,
    bool navigation = false,
  }) {
    if (_consumers.containsKey(id)) {
      throw StateError('Duplicate input owner: $id');
    }
    final consumer = _Consumer(id, priority, claims, onEvent, navigation);
    _consumers[id] = consumer;
    _subscription ??= _source.events.listen(_dispatch);
    return Registration(() {
      for (final pointer in _owners.keys.toList()) {
        if (_owners[pointer] == consumer) _cancel(pointer);
      }
      consumer.active = false;
      _consumers.remove(id);
      if (_consumers.isEmpty) {
        unawaited(_subscription?.cancel());
        _subscription = null;
        _pointers.clear();
      }
    });
  }

  /// A host-owned overlay can suspend scene gestures for its focus lifetime.
  /// Existing owners receive cancellation; blocked sequences cannot resume.
  Registration block() {
    _blocks++;
    cancelAll();
    return Registration(() => _blocks--);
  }

  void cancelAll() {
    for (final pointer in _owners.keys.toList()) {
      _cancel(pointer);
    }
    _pointers.clear();
  }

  List<_Consumer> get _ordered => _consumers.values.toList()
    ..sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      return priority != 0 ? priority : a.id.compareTo(b.id);
    });

  _Consumer? _winner(ScenePointerEvent event, {bool navigation = false}) {
    for (final consumer in _ordered) {
      if (!consumer.active || (navigation && !consumer.navigation)) continue;
      try {
        if (consumer.claims(event)) return consumer;
      } catch (error, stack) {
        Zone.current.handleUncaughtError(error, stack);
      }
    }
    return null;
  }

  void _send(_Consumer? consumer, ScenePointerEvent event) {
    if (consumer == null || !consumer.active) return;
    try {
      consumer.onEvent(event);
    } catch (error, stack) {
      Zone.current.handleUncaughtError(error, stack);
    }
  }

  ScenePointerEvent _copy(ScenePointerEvent event, ScenePointerPhase phase) =>
      ScenePointerEvent(
        point: event.point,
        phase: phase,
        pointer: event.pointer,
        buttons: event.buttons,
        kind: event.kind,
        time: event.time,
        modifiers: event.modifiers,
      );

  void _cancel(int pointer) {
    final owner = _owners.remove(pointer);
    final event = _pointers[pointer];
    if (event != null) _send(owner, _copy(event, ScenePointerPhase.cancel));
  }

  void _dispatch(ScenePointerEvent event) {
    if (blocked) return;
    switch (event.phase) {
      case ScenePointerPhase.down:
        _cancel(event.pointer);
        _pointers[event.pointer] = event;
        final touches = _pointers.values
            .where((e) => e.kind == ScenePointerKind.touch)
            .toList();
        final navigation =
            event.kind == ScenePointerKind.touch && touches.length > 1
            ? _winner(event, navigation: true)
            : null;
        if (navigation != null) {
          for (final touch in touches) {
            if (_owners[touch.pointer] == navigation) continue;
            _cancel(touch.pointer);
            if (!navigation.active || blocked) break;
            _owners[touch.pointer] = navigation;
            _send(navigation, _copy(touch, ScenePointerPhase.down));
          }
        } else {
          final winner = _winner(event);
          if (winner != null) {
            _owners[event.pointer] = winner;
            _send(winner, event);
          }
        }
      case ScenePointerPhase.move:
        if (_pointers.containsKey(event.pointer)) {
          _pointers[event.pointer] = event;
          _send(_owners[event.pointer], event);
        }
      case ScenePointerPhase.up:
      case ScenePointerPhase.cancel:
        final owner = _owners.remove(event.pointer);
        _pointers.remove(event.pointer);
        _send(owner, event);
      case ScenePointerPhase.hover:
        for (final consumer in _ordered) {
          _send(consumer, event);
        }
      default:
        _send(_winner(event), event);
    }
  }
}

final class _Consumer {
  final String id;
  final int priority;
  final bool Function(ScenePointerEvent) claims;
  final void Function(ScenePointerEvent) onEvent;
  final bool navigation;
  bool active = true;
  _Consumer(this.id, this.priority, this.claims, this.onEvent, this.navigation);
}
