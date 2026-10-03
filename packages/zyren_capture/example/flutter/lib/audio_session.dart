import 'dart:io';
import 'package:flutter/services.dart';

/// App policy: pause on duck/focus loss, require a new Play after a permanent
/// loss or removed route, and reacquire only while this view is foreground.
final class LabAudioSession {
  final void Function() suspend, resume;
  final void Function(Object) onError;
  final MethodChannel channel;
  final bool mobile;
  bool foreground = true,
      allowed = false,
      wantsPlayback = false,
      _closed = false;
  int _epoch = 0;
  LabAudioSession({
    required this.suspend,
    required this.resume,
    required this.onError,
    this.channel = const MethodChannel('zyren/smaller-lab/audio-session'),
    bool? mobile,
  }) : mobile = mobile ?? (Platform.isAndroid || Platform.isIOS) {
    allowed = !this.mobile;
    if (this.mobile) channel.setMethodCallHandler(_event);
  }
  Future<bool> play() async {
    if (_closed) return false;
    wantsPlayback = true;
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
      return granted;
    } catch (error) {
      if (_closed || epoch != _epoch) return false;
      allowed = false;
      suspend();
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
      if (wantsPlayback) await play();
      return;
    }
    allowed = false;
    _epoch++;
    suspend();
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
    final state = call.arguments as String;
    if (state == 'gain' && foreground && wantsPlayback) {
      await play();
      return;
    }
    allowed = false;
    suspend();
    if (state == 'loss' || state == 'routeLost') wantsPlayback = false;
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    allowed = false;
    if (mobile) {
      channel.setMethodCallHandler(null);
      channel.invokeMethod<void>('release').catchError((Object error) {
        onError(error);
      });
    }
  }
}
