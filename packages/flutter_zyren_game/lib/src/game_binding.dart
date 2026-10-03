import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_interaction/flutter_zyren_interaction.dart';
import 'package:zyren_game/zyren_game.dart';
import 'dart:async';
import 'input_adapter.dart';
import 'gamepad_adapter.dart';
import 'lifecycle.dart';
import 'package:flutter_zyren_audio/flutter_zyren_audio.dart';

/// Borrows a configured native controller. Its host owns simulation and resources.
class GameSceneBinding extends StatefulWidget {
  final SceneController controller;
  final GameSession session;
  final GameActionState actions;
  final SceneInteractionRouter? interaction;
  final AudioFocusSession? audioFocus;
  final Widget? hud;
  final Widget Function(SceneController)? viewportBuilder;
  final bool autofocus, enableGamepads;
  final void Function(Object)? onGamepadError;
  final void Function(ScenePointerEvent)? onPointer;
  const GameSceneBinding({
    super.key,
    required this.controller,
    required this.session,
    required this.actions,
    this.interaction,
    this.audioFocus,
    this.hud,
    this.viewportBuilder,
    this.autofocus = false,
    this.enableGamepads = false,
    this.onGamepadError,
    this.onPointer,
  });
  @override
  State<GameSceneBinding> createState() => _GameSceneBindingState();
}

class _GameSceneBindingState extends State<GameSceneBinding> {
  final _focus = FocusNode(debugLabel: 'Game viewport');
  late GameInputAdapter _input;
  GameEventSubscription? _session;
  GameLifecycleBinding? _lifecycle;
  GamepadAdapter? _gamepads;
  StreamSubscription<GameInputEvent>? _gamepadEvents;
  void _focusChanged() => _input.setFocus(_focus.hasPrimaryFocus);
  void _bind() {
    _input = GameInputAdapter(
      actions: widget.actions,
      source: widget.controller.input,
      onPointer: widget.onPointer,
    );
    if (widget.enableGamepads) {
      _gamepads = GamepadAdapter.native(input: _input);
      _gamepadEvents = _gamepads!.events.listen(
        (_) {},
        onError: (Object error) => widget.onGamepadError?.call(error),
      );
      unawaited(_gamepads!.start());
    }
    _lifecycle = GameLifecycleBinding(
      session: widget.session,
      actions: widget.actions,
      audio: widget.audioFocus,
      router: _input.router,
    );
    _session = widget.session.listenState(() {
      _input.setEnabled(
        !widget.session.paused &&
            !widget.session.isClosed &&
            widget.session.fault == null,
      );
    });
    _input.setEnabled(!widget.session.paused && !widget.session.isClosed);
    _focusChanged();
  }

  @override
  void initState() {
    super.initState();
    _bind();
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(GameSceneBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.actions != widget.actions ||
        oldWidget.session != widget.session ||
        oldWidget.audioFocus != widget.audioFocus ||
        oldWidget.enableGamepads != widget.enableGamepads ||
        oldWidget.onPointer != widget.onPointer) {
      _session?.cancel();
      unawaited(_gamepadEvents?.cancel());
      unawaited(_gamepads?.dispose());
      _gamepadEvents = null;
      _gamepads = null;
      _lifecycle?.dispose();
      _lifecycle = null;
      _input.dispose();
      _bind();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _session?.cancel();
    unawaited(_gamepadEvents?.cancel());
    unawaited(_gamepads?.dispose());
    _lifecycle?.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget view =
        widget.viewportBuilder?.call(widget.controller) ??
        SceneView(controller: widget.controller);
    if (widget.interaction case final router?) {
      view = SceneInteractionOverlay(
        controller: widget.controller,
        router: router,
        child: view,
      );
    }
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: (_, event) => _input.key(event),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(onPointerDown: (_) => _focus.requestFocus(), child: view),
          ?widget.hud,
        ],
      ),
    );
  }
}
