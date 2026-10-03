import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_game/zyren_game.dart';
import '../zyren_game_native.dart';

final class _SoundBinding {
  final AudioEmitter emitter;
  final EmitterSettings settings;
  _SoundBinding(this.emitter) : settings = emitter.settings;
}

/// Borrows the native mixer and emitters. Its scope owns only event registrations.
final class GameAudioEvents {
  final SpatialAudio audio;
  final void Function(Object error) onError;
  final Map<String, _SoundBinding> _bindings = {};
  late final GameEventSubscription _subscription;
  bool muted = false, _closed = false;
  GameAudioEvents({
    required GameEventBus events,
    required this.audio,
    required AttachmentScope scope,
    required this.onError,
  }) {
    if (scope.isClosed || audio.isClosed) {
      throw StateError('Audio binding owner is closed.');
    }
    _subscription = events.listen((event) {
      if (_closed ||
          muted ||
          audio.isSuspended ||
          event.payload is! GameSoundEvent) {
        return;
      }
      final sound = event.payload as GameSoundEvent;
      final binding = _bindings[sound.category];
      if (binding == null) return;
      try {
        final emitter = binding.emitter;
        if (emitter.isClosed || audio.isClosed) {
          throw StateError('Gameplay emitter has closed.');
        }
        final parent = emitter.node.parent;
        emitter.node.position = parent == null
            ? sound.position
            : Vec3.fromVectorMath(
                parent.worldMatrix.inverted().toVectorMath().transform3(
                  sound.position.toVectorMath(),
                ),
              );
        final authored = binding.settings;
        emitter.configure(
          EmitterSettings(
            volume: authored.volume * sound.loudness,
            minDistance: authored.minDistance,
            maxDistance: authored.maxDistance,
            rolloff: authored.rolloff,
            attenuation: authored.attenuation,
            loop: authored.loop,
          ),
        );
        emitter.play(restart: true);
      } catch (error) {
        onError(error);
      }
    });
    scope.onClose(close);
  }
  Registration bind(String category, AudioEmitter emitter) {
    if (_closed ||
        category.isEmpty ||
        category.length > 128 ||
        _bindings.containsKey(category) ||
        _bindings.length >= 128 ||
        _bindings.values.any((b) => identical(b.emitter, emitter)) ||
        emitter.isClosed ||
        !audio.emitters.contains(emitter)) {
      throw StateError('Invalid or duplicate gameplay sound binding.');
    }
    final binding = _SoundBinding(emitter);
    _bindings[category] = binding;
    return Registration(() {
      if (identical(_bindings[category], binding)) _bindings.remove(category);
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _subscription.cancel();
    for (final binding in _bindings.values) {
      if (!binding.emitter.isClosed && !audio.isClosed) {
        try {
          binding.emitter.pause();
          binding.emitter.configure(binding.settings);
        } catch (error) {
          onError(error);
        }
      }
    }
    _bindings.clear();
  }
}
