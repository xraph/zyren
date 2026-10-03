import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_zyren_audio/flutter_zyren_audio.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';

/// App suspension releases held input and invalidates queued model decisions.
final class GameLifecycleBinding extends WidgetsBindingObserver {
  final GameSession session;
  final GameActionState actions;
  final AudioFocusSession? audio;
  final InputRouter? router;
  bool _closed = false, _resumeSession = false, _foreground = true;
  int _epoch = 0;
  final bool _observe;
  void Function()? _cancelAudio;
  void _suspend() {
    if (!session.paused && !session.isClosed && session.fault == null) {
      _resumeSession = true;
      session.pause();
    }
    actions.enabled = false;
    actions.releaseEveryDevice();
    router?.cancelAll();
  }

  void _audioChanged() {
    if (_closed) return;
    if (audio?.allowed == false) {
      _suspend();
      return;
    }
    if (_foreground) _restore();
  }

  void _restore() {
    actions.releaseEveryDevice();
    if (_resumeSession && !session.isClosed && session.fault == null) {
      session.resume();
    }
    _resumeSession = false;
    actions.enabled =
        !session.paused && !session.isClosed && session.fault == null;
  }

  GameLifecycleBinding({
    required this.session,
    required this.actions,
    this.audio,
    this.router,
    bool observe = true,
  }) : _observe = observe {
    _cancelAudio = audio?.addStateListener(_audioChanged);
    if (observe) {
      WidgetsBinding.instance.addObserver(this);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) {
        unawaited(setForeground(false));
      }
    }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(setForeground(state == AppLifecycleState.resumed));
  }

  Future<void> setForeground(bool foreground) async {
    if (_closed) return;
    _foreground = foreground;
    final epoch = ++_epoch;
    if (!foreground) {
      _suspend();
      await audio?.setForeground(false);
    } else {
      await audio?.setForeground(true);
      if (_closed || epoch != _epoch || !_foreground) return;
      // Permanent focus loss retains the pause until the host requests Play.
      if (audio?.allowed != false) _restore();
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _cancelAudio?.call();
    if (_observe) WidgetsBinding.instance.removeObserver(this);
    actions.releaseEveryDevice();
  }
}
