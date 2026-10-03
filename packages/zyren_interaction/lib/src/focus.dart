part of '../zyren_interaction.dart';

/// Stable scene identity and host-supplied accessibility text and actions.
final class SceneFocusTarget {
  final Object3D object;
  final String label;
  final double order;
  final void Function()? onActivate;
  final void Function(SceneKeyEvent)? onKey;
  const SceneFocusTarget._(
    this.object,
    this.label,
    this.order,
    this.onActivate,
    this.onKey,
  );
}

/// Object focus is separate from selection. The viewport host owns OS focus.
final class SceneObjectFocus {
  final Scene scene;
  final _targets = <Object3D, SceneFocusTarget>{};
  final _changes = StreamController<void>.broadcast();
  late final StreamSubscription<int> _sceneChanges;
  Object3D? _focused;
  Registration? _connection, _keys;
  KeyboardInputSource? _input;
  bool _disposed = false;
  SceneObjectFocus(this.scene) {
    _sceneChanges = scene.changes.listen((_) => _prune());
  }
  Stream<void> get changes => _changes.stream;
  Object3D? get focusedObject => _focused;
  List<SceneFocusTarget> get targets =>
      _targets.values.where((t) => _live(t.object)).toList()..sort((a, b) {
        final order = a.order.compareTo(b.order);
        return order != 0 ? order : a.object.id.compareTo(b.object.id);
      });
  bool _member(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (identical(node, scene)) return true;
    }
    return false;
  }

  bool _live(Object3D object) {
    if (!_member(object)) return false;
    for (Object3D? node = object; node != null; node = node.parent) {
      if (!node.visible) return false;
    }
    return true;
  }

  Registration register(
    Object3D object, {
    required String label,
    double order = 0,
    void Function()? onActivate,
    void Function(SceneKeyEvent)? onKey,
  }) {
    if (_disposed) throw StateError('Focus has been disposed.');
    if (!_member(object) || label.trim().isEmpty || !order.isFinite) {
      throw ArgumentError(
        'Focus requires a scene object, label and finite order.',
      );
    }
    if (_targets.containsKey(object)) {
      throw StateError('Object already has focus metadata.');
    }
    final target = SceneFocusTarget._(object, label, order, onActivate, onKey);
    _targets[object] = target;
    _syncKeys();
    _notify();
    return Registration(() {
      if (!identical(_targets[object], target)) return;
      _targets.remove(object);
      if (identical(_focused, object)) blur();
      _syncKeys();
      _notify();
    });
  }

  bool request(Object3D object) {
    if (_disposed || !_targets.containsKey(object) || !_live(object)) {
      return false;
    }
    if (!identical(_focused, object)) {
      _focused = object;
      _notify();
    }
    return true;
  }

  void blur() {
    if (_focused != null) {
      _focused = null;
      _notify();
    }
  }

  bool activate([Object3D? object]) {
    final target = _targets[object ?? _focused];
    if (_disposed ||
        target == null ||
        !_live(target.object) ||
        target.onActivate == null) {
      return false;
    }
    request(target.object);
    target.onActivate!();
    return true;
  }

  void traverse({bool backwards = false}) {
    final available = targets;
    if (available.isEmpty) {
      blur();
      return;
    }
    final index = available.indexWhere((t) => identical(t.object, _focused));
    final next = index < 0
        ? (backwards ? available.length - 1 : 0)
        : (index + (backwards ? -1 : 1)) % available.length;
    request(available[next].object);
  }

  void handleKey(SceneKeyEvent event) {
    if (_disposed) return;
    _prune();
    if (event.phase == SceneKeyPhase.cancel) {
      blur();
      return;
    }
    if (event.phase == SceneKeyPhase.down) {
      switch (event.key) {
        case SceneKey.tab:
          traverse(backwards: event.modifiers.contains(SceneModifier.shift));
          return;
        case SceneKey.escape:
          blur();
          return;
        case SceneKey.enter:
        case SceneKey.space:
          activate();
          return;
        default:
          break;
      }
    }
    _targets[_focused]?.onKey?.call(event);
  }

  Registration connect(KeyboardInputSource input) {
    if (_disposed || _connection != null) {
      throw StateError('Focus is closed or connected.');
    }
    _input = input;
    final scope = AttachmentScope();
    scope.listen(input.keyEvents, handleKey);
    if (input is FocusInputSource) {
      scope.listen((input as FocusInputSource).focusChanges, (focused) {
        if (!focused) blur();
      });
    }
    _syncKeys();
    return _connection = Registration(() {
      _connection = null;
      _keys?.dispose();
      _keys = null;
      _input = null;
      scope.close();
      blur();
    });
  }

  void _syncKeys() {
    if (_input == null) return;
    if (targets.isEmpty) {
      _keys?.dispose();
      _keys = null;
    } else {
      _keys ??= _input!.registerKeys({
        SceneKey.tab,
        SceneKey.enter,
        SceneKey.space,
        SceneKey.escape,
      });
    }
  }

  void _prune() {
    _targets.removeWhere((object, _) => !_member(object));
    if (_focused != null &&
        (!_targets.containsKey(_focused) || !_live(_focused!))) {
      blur();
    }
    _syncKeys();
    _notify();
  }

  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  void dispose() {
    if (_disposed) return;
    _connection?.dispose();
    _disposed = true;
    _targets.clear();
    _focused = null;
    unawaited(_sceneChanges.cancel());
    unawaited(_changes.close());
  }
}
