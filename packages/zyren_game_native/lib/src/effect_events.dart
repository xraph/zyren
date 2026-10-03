import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_particles/zyren_particles.dart';

final class GameEffectEvent {
  final String id, effect;
  final int count;
  GameEffectEvent({
    required this.id,
    required this.effect,
    required this.count,
  }) {
    if (id.isEmpty ||
        id.length > 1024 ||
        effect.isEmpty ||
        effect.length > 128 ||
        count < 1 ||
        count > 65536) {
      throw ArgumentError('Invalid game effect event.');
    }
  }
}

final class _EffectBinding {
  final String emitter;
  _EffectBinding(this.emitter);
}

/// Bounded event delivery; ParticleController retains simulation and GPU ownership.
final class GameEffectEvents {
  final ParticleController particles;
  final int capacity;
  final void Function(Object error) onError;
  final Map<String, _EffectBinding> _bindings = {};
  final Set<String> _receipts = {};
  late final GameEventSubscription _subscription;
  Future<void> _queue = Future.value();
  Future<void>? _closing;
  int _pending = 0, _tick = -1;
  bool _closed = false;
  final List<Object> _errors = [];
  List<Object> get errors => List.unmodifiable(_errors);
  void _report(Object error) {
    if (_errors.length < capacity) _errors.add(error);
    try {
      onError(error);
    } catch (callbackError) {
      if (_errors.length < capacity) _errors.add(callbackError);
    }
  }

  Future<void> get settled => _queue;
  int get pending => _pending;
  GameEffectEvents({
    required GameEventBus events,
    required this.particles,
    required AttachmentScope scope,
    required this.onError,
    this.capacity = 128,
  }) {
    if (scope.isClosed ||
        particles.isClosed ||
        capacity < 1 ||
        capacity > 1024) {
      throw ArgumentError('Invalid effect owner or limits.');
    }
    _subscription = events.listen((event) {
      if (_closed || event.payload is! GameEffectEvent) return;
      final effect = event.payload as GameEffectEvent;
      final binding = _bindings[effect.effect];
      if (binding == null) return;
      if (event.tick < _tick) {
        _report(StateError('Stale game effect tick.'));
        return;
      }
      if (_tick != event.tick) {
        _tick = event.tick;
        _receipts.clear();
      }
      if (_receipts.contains(effect.id)) return;
      if (_pending >= capacity || _receipts.length >= capacity) {
        _report(StateError('Game effect queue is full.'));
        return;
      }
      _receipts.add(effect.id);
      _pending++;
      _queue = _queue.then((_) async {
        try {
          if (!_closed && identical(_bindings[effect.effect], binding)) {
            await particles.burst(binding.emitter, effect.count);
          }
        } catch (error) {
          _report(error);
        } finally {
          _pending--;
        }
      });
      _queue.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    });
    scope.onClose(close);
  }
  Registration bind(String effect, String emitterName) {
    if (_closed ||
        effect.isEmpty ||
        effect.length > 128 ||
        _bindings.containsKey(effect) ||
        _bindings.length >= 128 ||
        _bindings.values.any((b) => b.emitter == emitterName) ||
        !particles.names.contains(emitterName)) {
      throw StateError('Invalid or duplicate game effect binding.');
    }
    final binding = _EffectBinding(emitterName);
    _bindings[effect] = binding;
    return Registration(() {
      if (identical(_bindings[effect], binding)) _bindings.remove(effect);
    });
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _subscription.cancel();
    return _closing = () async {
      try {
        await _queue;
      } finally {
        final names = _bindings.values.map((b) => b.emitter).toList();
        _bindings.clear();
        if (!particles.isClosed) {
          for (final name in names) {
            try {
              await particles.stop(name, clear: true);
            } catch (error) {
              _report(error);
            }
          }
        }
      }
    }();
  }
}
