import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pauses on ducking or focus loss and reacquires only while foregrounded.
///
/// You must request Play again after permanent loss or a removed route. Only one
/// mobile session may own a messenger/channel pair. Dispose that session and
/// await [released] before constructing its replacement.
final class AudioFocusSession {
  static final _owners =
      HashMap<BinaryMessenger, Map<String, AudioFocusSession>>.identity();
  final _released = Completer<void>();
  final _listeners = <Object, void Function()>{};
  late (bool, bool, bool) _published;
  final void Function() suspend, resume;
  final void Function(Object) onError;
  final MethodChannel channel;
  final bool mobile;
  bool foreground = true,
      allowed = false,
      wantsPlayback = false,
      _closed = false;
  int _epoch = 0;
  AudioFocusSession({
    required this.suspend,
    required this.resume,
    required this.onError,
    this.channel = const MethodChannel('zyren/audio-session'),
    bool? mobile,
  }) : mobile = mobile ?? (Platform.isAndroid || Platform.isIOS) {
    allowed = !this.mobile;
    _published = (foreground, allowed, wantsPlayback);
    if (this.mobile) {
      final owners = _owners.putIfAbsent(channel.binaryMessenger, () => {});
      if (owners.containsKey(channel.name)) {
        throw StateError(
          'An AudioFocusSession already owns ${channel.name}. '
          'Dispose it and await released before creating another session.',
        );
      }
      owners[channel.name] = this;
      try {
        channel.setMethodCallHandler(_event);
      } catch (_) {
        _removeOwner();
        rethrow;
      }
    }
  }
  Future<bool> play() async {
    if (_closed) return false;
    wantsPlayback = true;
    _notifyState();
    if (_closed || !foreground || !wantsPlayback) return false;
    final epoch = ++_epoch;
    try {
      final granted =
          !mobile || await channel.invokeMethod<bool>('acquire') == true;
      if (_closed || !foreground || epoch != _epoch) return false;
      allowed = granted;
      if (granted) {
        resume();
      } else {
        suspend();
      }
      _notifyState();
      return granted;
    } catch (error) {
      if (_closed || epoch != _epoch) return false;
      allowed = false;
      suspend();
      _notifyState();
      onError(error);
      return false;
    }
  }

  Future<void> pause() async {
    if (_closed) return;
    wantsPlayback = false;
    allowed = false;
    _epoch++;
    suspend();
    _notifyState();
    if (mobile) {
      try {
        await channel.invokeMethod<void>('release');
      } catch (error) {
        onError(error);
      }
    }
  }

  Future<void> setForeground(bool value) async {
    if (_closed) return;
    foreground = value;
    if (value) {
      _notifyState();
      if (wantsPlayback) await play();
      return;
    }
    allowed = false;
    _epoch++;
    suspend();
    _notifyState();
    if (mobile) {
      try {
        await channel.invokeMethod<void>('release');
      } catch (error) {
        onError(error);
      }
    }
  }

  Future<void> _event(MethodCall call) async {
    if (_closed || call.method != 'focus') return;
    _epoch++;
    final state = call.arguments;
    if (state is! String) return;
    if (state == 'gain' && foreground && wantsPlayback) {
      await play();
      return;
    }
    allowed = false;
    suspend();
    if (state == 'loss' || state == 'routeLost') wantsPlayback = false;
    _notifyState();
  }

  /// Observes foreground, permission and playback intent changes.
  ///
  /// You can register up to 32 listeners. The returned function removes this
  /// registration and can be called repeatedly. Disposal emits a final change
  /// and removes every listener. Listener exceptions go to [FlutterError].
  void Function() addStateListener(void Function() listener) {
    if (_closed) throw StateError('The audio focus session is disposed.');
    if (_listeners.length >= 32) {
      throw StateError('Audio focus listener limit reached.');
    }
    final token = Object();
    _listeners[token] = listener;
    return () {
      _listeners.remove(token);
    };
  }

  void _notifyState({bool force = false}) {
    final state = (foreground, allowed, wantsPlayback);
    if (!force && state == _published) return;
    _published = state;
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        entry.value();
      } catch (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'flutter_zyren_audio',
            context: ErrorDescription(
              'while notifying an audio focus listener',
            ),
          ),
        );
      }
    }
  }

  /// Completes after [dispose] has released native focus and channel ownership.
  /// You can await this even when native release reports an error to [onError].
  Future<void> get released => _released.future;

  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    allowed = false;
    _notifyState(force: true);
    _listeners.clear();
    if (mobile) {
      channel.setMethodCallHandler(null);
      unawaited(_finishDisposal());
    } else {
      _released.complete();
    }
  }

  Future<void> _finishDisposal() async {
    try {
      await channel.invokeMethod<void>('release');
    } catch (error) {
      onError(error);
    } finally {
      _removeOwner();
      _released.complete();
    }
  }

  void _removeOwner() {
    final owners = _owners[channel.binaryMessenger];
    if (owners?[channel.name] != this) return;
    owners!.remove(channel.name);
    if (owners.isEmpty) _owners.remove(channel.binaryMessenger);
  }
}
