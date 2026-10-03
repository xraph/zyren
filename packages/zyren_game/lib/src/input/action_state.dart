part of '../../zyren_game.dart';

final class GameActionSnapshot {
  final int revision;
  final Map<String, double> values;
  GameActionSnapshot._(this.revision, Map<String, double> values)
    : values = Map.unmodifiable(values);
}

final class _GameControlValue {
  final String action;
  final double value;
  final int timestamp;
  const _GameControlValue(this.action, this.value, this.timestamp);
}

/// Semantic input only. The host router retains pointer and focus ownership.
final class GameActionState {
  GameInputMap _map;
  final int maxDevices;
  final Map<String, Map<Object, _GameControlValue>> _devices = {};
  final Map<int, void Function()> _listeners = {};
  final Map<String, Set<String>> _presses = {};
  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    releaseEveryDevice();
  }

  int _revision = 0, _listenerId = 0, _directTime = 0;
  int _releaseRevision = 0;

  /// Changes whenever all input is released or the action map is rebound.
  /// Hosts use this to discard their local held keys and gesture state.
  int get releaseRevision => _releaseRevision;
  GameActionState(this._map, {this.maxDevices = 32}) {
    _limit(maxDevices, 64, 'maxDevices');
  }
  GameInputMap get inputMap => _map;
  GameActionSnapshot get snapshot => GameActionSnapshot._(_revision, {
    for (final action in _map.actions.keys) action: axis(action),
  });
  GameEventSubscription listen(void Function() listener) {
    if (_listeners.length >= 1024) {
      throw StateError('Action listener limit exceeded.');
    }
    final id = _listenerId++;
    _listeners[id] = listener;
    return GameEventSubscription._(() => _listeners.remove(id));
  }

  void _changed() {
    _revision++;
    for (final id in _listeners.keys.toList()) {
      _listeners[id]?.call();
    }
  }

  bool accept(GameInputEvent event) {
    GameInputBinding? binding;
    for (final candidate in _map.bindings) {
      if (candidate.control == event.control) {
        binding = candidate;
        break;
      }
    }
    if (binding == null) return false;
    return _set(
      event.deviceId,
      event.control,
      binding.action,
      event.consumed ? 0 : event.value * binding.scale,
      event.timestamp,
    );
  }

  bool _set(
    String device,
    Object control,
    String action,
    double value,
    int time,
  ) {
    _id(device);
    if (!_enabled) return false;
    if (!_map.actions.containsKey(action) ||
        !value.isFinite ||
        value.abs() > 1) {
      throw ArgumentError('Unknown action or invalid axis.');
    }
    final previous = _devices[device]?[control];
    if (previous != null && time < previous.timestamp) return false;
    if (!_devices.containsKey(device) && _devices.length >= maxDevices) {
      throw StateError('Input device limit exceeded.');
    }
    final controls = _devices.putIfAbsent(device, () => {});
    if (!controls.containsKey(control) && controls.length >= 640) {
      throw StateError('Input control limit exceeded.');
    }
    if (_map.actions[action]!.button &&
        value > .5 &&
        (previous?.value ?? 0) <= .5) {
      _presses.putIfAbsent(device, () => {}).add(action);
    }
    controls[control] = _GameControlValue(action, value, time);
    _changed();
    return true;
  }

  void setAxis({
    required String deviceId,
    required String action,
    required double value,
  }) {
    _set(deviceId, (action: action), action, value, ++_directTime);
  }

  void setButton({
    required String deviceId,
    required String action,
    required bool pressed,
  }) {
    if (_map.actions[action]?.button != true) {
      throw ArgumentError('Action is not a button.');
    }
    setAxis(deviceId: deviceId, action: action, value: pressed ? 1 : 0);
  }

  double axis(String action) {
    final definition = _map.actions[action];
    if (definition == null) throw ArgumentError('Unknown action: $action.');
    var value = 0.0;
    for (final device in _devices.values) {
      for (final control in device.values) {
        if (control.action != action) continue;
        if (definition.button) {
          if (control.value > 0.5) return 1;
        } else {
          value += control.value;
        }
      }
    }
    if (definition.button) return 0;
    value = value.clamp(-1.0, 1.0);
    if (value.abs() <= definition.deadZone) return 0;
    return value.sign *
        (value.abs() - definition.deadZone) /
        (1 - definition.deadZone);
  }

  bool pressed(String action) => axis(action) > .5;
  bool takePressed(String action) {
    if (_map.actions[action]?.button != true) {
      throw ArgumentError('Action is not a button.');
    }
    var found = false;
    for (final presses in _presses.values) {
      if (presses.remove(action)) found = true;
    }
    return found;
  }

  void releaseAll(String deviceId) {
    _presses.remove(deviceId);
    if (_devices.remove(deviceId) != null) _changed();
  }

  void releaseEveryDevice() {
    _devices.clear();
    _presses.clear();
    _releaseRevision++;
    _changed();
  }

  void rebind(GameInputMap map) {
    _devices.clear();
    _presses.clear();
    _map = map;
    _releaseRevision++;
    _changed();
  }
}
