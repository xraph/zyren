import 'dart:async';
import 'dart:io';
import 'package:gamepads/gamepads.dart' as native;
import 'package:zyren_game/zyren_game.dart';
import 'input_adapter.dart';

final class GamepadConnection {
  final String id, name;
  final bool connected;
  const GamepadConnection(this.id, this.name, this.connected);
}

/// Uses the audited gamepads 0.1.12 native backends and normalized controls.
final class GamepadAdapter {
  final GameInputAdapter input;
  final Stream<GameInputEvent> _source;
  final Stream<GamepadConnection> _connections;
  final Future<List<GamepadConnection>> Function() _list;
  final _events = StreamController<GameInputEvent>.broadcast(sync: true);
  final Map<String, GamepadConnection> _devices = {};
  final Map<String, bool> _changesDuringList = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final _clock = Stopwatch()..start();
  int _lastTimestamp = -1;
  bool _started = false, _closed = false, _listing = false;
  Object? error;
  Stream<GameInputEvent> get events => _events.stream;
  Map<String, GamepadConnection> get devices => Map.unmodifiable(_devices);
  GamepadAdapter({
    required this.input,
    required Stream<GameInputEvent> source,
    required Stream<GamepadConnection> connections,
    required Future<List<GamepadConnection>> Function() listDevices,
  }) : _source = source,
       _connections = connections,
       _list = listDevices;
  factory GamepadAdapter.native({required GameInputAdapter input}) {
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux)) {
      throw UnsupportedError('Game controllers require a native platform.');
    }
    return GamepadAdapter(
      input: input,
      source: native.Gamepads.normalizedEvents.map(
        (event) => GameInputEvent(
          deviceId: 'gamepad:${event.gamepadId}',
          control: event.button != null
              ? 'button.${event.button!.name}'
              : 'axis.${event.axis!.name}',
          value: event.value,
          // Platform clocks have different units and may use wall time.
          // The adapter stamps arrival order below with its monotonic clock.
          timestamp: 0,
        ),
      ),
      connections: native.Gamepads.connectionEvents.map(
        (event) => GamepadConnection(
          'gamepad:${event.gamepadId}',
          event.name,
          event.type == native.GamepadConnectionEventType.connected,
        ),
      ),
      listDevices: () async {
        final controllers = await native.Gamepads.list();
        try {
          return [
            for (final controller in controllers)
              GamepadConnection(
                'gamepad:${controller.id}',
                controller.name,
                true,
              ),
          ];
        } finally {
          for (final controller in controllers) {
            controller.dispose();
          }
        }
      },
    );
  }
  Future<void> start() async {
    if (_closed || _started) {
      throw StateError('Gamepad adapter already started or closed.');
    }
    _started = true;
    _listing = true;
    _subscriptions.add(_connections.listen(_connection, onError: _failed));
    _subscriptions.add(
      _source.listen((event) {
        if (_closed || !_devices.containsKey(event.deviceId)) return;
        try {
          final elapsed = _clock.elapsedMicroseconds;
          _lastTimestamp = elapsed > _lastTimestamp
              ? elapsed
              : _lastTimestamp + 1;
          final received = GameInputEvent(
            deviceId: event.deviceId,
            control: event.control,
            value: event.value,
            timestamp: _lastTimestamp,
            consumed: event.consumed,
          );
          input.accept(received);
          _events.add(received);
        } catch (failure) {
          _failed(failure);
        }
      }, onError: _failed),
    );
    try {
      final initial = await _list();
      if (_closed) return;
      if (initial.length > input.actions.maxDevices) {
        throw StateError('Gamepad device limit exceeded.');
      }
      for (final device in initial) {
        if (!_changesDuringList.containsKey(device.id)) _connection(device);
      }
    } catch (failure) {
      if (!_closed) _failed(failure);
    } finally {
      _listing = false;
      _changesDuringList.clear();
    }
  }

  void _connection(GamepadConnection event) {
    if (_closed) return;
    if (event.id.isEmpty ||
        event.id.length > 1024 ||
        event.name.length > 1024) {
      _failed(ArgumentError('Invalid gamepad identity.'));
      return;
    }
    if (_listing) {
      if (_changesDuringList.length >= 128 &&
          !_changesDuringList.containsKey(event.id)) {
        _failed(StateError('Gamepad connection event limit exceeded.'));
        return;
      }
      _changesDuringList[event.id] = event.connected;
    }
    input.actions.releaseAll(event.id);
    if (event.connected) {
      if (_devices.length >= input.actions.maxDevices &&
          !_devices.containsKey(event.id)) {
        _failed(StateError('Gamepad device limit exceeded.'));
        return;
      }
      _devices[event.id] = event;
    } else {
      _devices.remove(event.id);
    }
  }

  void _failed(Object failure) {
    error = failure;
    for (final id in _devices.keys) {
      input.actions.releaseAll(id);
    }
    _devices.clear();
    if (!_closed) _events.addError(failure);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    for (final id in _devices.keys) {
      input.actions.releaseAll(id);
    }
    _devices.clear();
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    _subscriptions.clear();
    await _events.close();
  }
}
