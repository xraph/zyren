import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';

/// Registers with the shared router. Editor tools and object capture keep priority.
final class GameInputAdapter {
  final GameActionState actions;
  final InputRouter router;
  final void Function(ScenePointerEvent)? onPointer;
  final List<Registration> _registrations = [];
  bool _focused = false, _enabled = true, _closed = false;
  GameInputAdapter({
    required this.actions,
    required InputSource source,
    this.onPointer,
    String id = 'game.input',
  }) : router = InputRouter.forSource(source) {
    _registrations.add(
      router.listenBlocked((blocked) {
        actions.enabled = _enabled && !blocked;
        if (blocked) actions.releaseEveryDevice();
      }),
    );
    _registrations.add(
      router.register(
        id: id,
        priority: InputPriority.navigation - 1,
        claims: (_) => active && onPointer != null,
        onEvent: (event) {
          if (event.phase == ScenePointerPhase.cancel || active) {
            onPointer?.call(event);
          }
        },
      ),
    );
    if (onPointer != null) {
      _registrations.add(source.registerGesture(SceneGesture.pointerDrag));
    }
  }
  bool get active => !_closed && _enabled && _focused && !router.blocked;
  void setFocus(bool value) {
    _focused = value;
    if (!value) _release();
  }

  void setEnabled(bool value) {
    _enabled = value;
    actions.enabled = value && !router.blocked;
    if (!value) _release();
  }

  void _release() {
    actions.releaseEveryDevice();
    router.cancelAll();
  }

  static String keyControl(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'key.space';
    return 'key.${key.keyLabel.toLowerCase().replaceAll(' ', '')}';
  }

  KeyEventResult key(KeyEvent event) {
    if (!active) return KeyEventResult.ignored;
    final canonical = keyControl(event.logicalKey);
    final label = event.logicalKey.keyLabel;
    final legacy = event.logicalKey == LogicalKeyboardKey.space
        ? 'Space'
        : RegExp(r'^[a-zA-Z]$').hasMatch(label)
        ? 'Key${label.toUpperCase()}'
        : canonical;
    // Persisted Studio maps used DOM letter names before canonical controls.
    // Prefer the current binding, so one key cannot publish two actions.
    final control = actions.inputMap.bindings.any((b) => b.control == canonical)
        ? canonical
        : legacy;
    final accepted = actions.accept(
      GameInputEvent(
        deviceId: 'keyboard',
        control: control,
        value: event is KeyUpEvent ? 0 : 1,
        timestamp: event.timeStamp.inMicroseconds,
      ),
    );
    return accepted ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool accept(GameInputEvent event) {
    if (!active) {
      actions.releaseAll(event.deviceId);
      return false;
    }
    return actions.accept(event);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    // Removing this consumer cancels its pointers without cancelling other owners.
    for (final registration in _registrations.reversed) {
      registration.dispose();
    }
    _registrations.clear();
    actions.releaseEveryDevice();
  }
}
