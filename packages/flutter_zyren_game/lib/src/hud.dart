import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zyren_game/zyren_game.dart';

/// A compact immutable view of input and the optional running session.
final class GameHudSnapshot {
  final GameActionSnapshot actions;
  final int? tick, epoch, entityCount;
  final bool? paused, failed;
  final double? droppedSeconds;
  GameHudSnapshot(GameActionState state, GameSession? session)
    : actions = state.snapshot,
      tick = session?.tick,
      epoch = session?.epoch,
      entityCount = session?.entities.length,
      paused = session?.paused,
      failed = session == null ? null : session.fault != null,
      droppedSeconds = session?.droppedSeconds;
}

class GameHud extends StatefulWidget {
  final GameActionState actions;
  final GameSession? session;
  final Widget Function(BuildContext, GameHudSnapshot) builder;
  const GameHud({
    super.key,
    required this.actions,
    this.session,
    required this.builder,
  });
  @override
  State<GameHud> createState() => _GameHudState();
}

class _GameHudState extends State<GameHud> {
  GameEventSubscription? _actions, _session;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _actions = widget.actions.listen(_changed);
    _session = widget.session?.listenState(_changed);
  }

  void _unbind() {
    _actions?.cancel();
    _session?.cancel();
  }

  @override
  void didUpdateWidget(GameHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions ||
        oldWidget.session != widget.session) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, GameHudSnapshot(widget.actions, widget.session));
}

/// A touch button releases its action on cancellation, focus loss and unmount.
class GameActionButton extends StatefulWidget {
  final GameActionState actions;
  final String action, label, deviceId;
  const GameActionButton({
    super.key,
    required this.actions,
    required this.action,
    required this.label,
    this.deviceId = 'touch',
  });
  @override
  State<GameActionButton> createState() => _GameActionButtonState();
}

class _GameActionButtonState extends State<GameActionButton> {
  static int _nextDevice = 0;
  final int _id = _nextDevice++;
  final Set<int> _pointers = {};
  bool _held = false;
  String get _device => '${widget.deviceId}:$_id';
  void _set(bool pressed) {
    if (_held == pressed) return;
    _held = pressed;
    widget.actions.setButton(
      deviceId: _device,
      action: widget.action,
      pressed: pressed,
    );
  }

  void _pulse() {
    if (_held || !widget.actions.enabled) return;
    _set(true);
    _set(false);
  }

  void _cancel() {
    _pointers.clear();
    _set(false);
  }

  @override
  void didUpdateWidget(GameActionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions ||
        oldWidget.action != widget.action ||
        oldWidget.deviceId != widget.deviceId) {
      oldWidget.actions.releaseAll('${oldWidget.deviceId}:$_id');
      _held = false;
      _pointers.clear();
    }
  }

  @override
  void dispose() {
    widget.actions.releaseAll(_device);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onFocusChange: (focused) {
      if (!focused) _cancel();
    },
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    },
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          _pulse();
          return null;
        },
      ),
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _pointers.add(event.pointer);
        _set(true);
      },
      onPointerUp: (event) {
        _pointers.remove(event.pointer);
        if (_pointers.isEmpty) _set(false);
      },
      onPointerCancel: (event) {
        _pointers.remove(event.pointer);
        if (_pointers.isEmpty) _set(false);
      },
      child: Semantics(
        button: true,
        label: widget.label,
        onTap: _pulse,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A bounded touch axis pair with keyboard arrows and separate axis semantics.
class GameAxisPad extends StatefulWidget {
  final GameActionState actions;
  final String xAction, yAction, label;
  final double extent;
  const GameAxisPad({
    super.key,
    required this.actions,
    required this.xAction,
    required this.yAction,
    required this.label,
    this.extent = 112,
  });
  @override
  State<GameAxisPad> createState() => _GameAxisPadState();
}

class _GameAxisPadState extends State<GameAxisPad> {
  late final String _device = 'touch-pad:${identityHashCode(this)}';
  final _keys = <LogicalKeyboardKey>{};
  Offset _pointer = Offset.zero;
  Offset get _value => Offset(
    (_pointer.dx +
            (_keys.contains(LogicalKeyboardKey.arrowRight) ? 1 : 0) -
            (_keys.contains(LogicalKeyboardKey.arrowLeft) ? 1 : 0))
        .clamp(-1.0, 1.0),
    (_pointer.dy +
            (_keys.contains(LogicalKeyboardKey.arrowUp) ? 1 : 0) -
            (_keys.contains(LogicalKeyboardKey.arrowDown) ? 1 : 0))
        .clamp(-1.0, 1.0),
  );
  void _publish() {
    widget.actions.setAxis(
      deviceId: _device,
      action: widget.xAction,
      value: _value.dx,
    );
    widget.actions.setAxis(
      deviceId: _device,
      action: widget.yAction,
      value: _value.dy,
    );
    if (mounted) setState(() {});
  }

  void _move(Offset position) {
    final center = widget.extent / 2;
    var value = Offset(
      (position.dx - center) / center,
      (center - position.dy) / center,
    );
    if (value.distance > 1) value = value / value.distance;
    _pointer = value;
    _publish();
  }

  void _cancel() {
    _keys.clear();
    _pointer = Offset.zero;
    _publish();
  }

  @override
  void didUpdateWidget(GameAxisPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions != widget.actions ||
        oldWidget.xAction != widget.xAction ||
        oldWidget.yAction != widget.yAction) {
      oldWidget.actions.releaseAll(_device);
      _keys.clear();
      _pointer = Offset.zero;
    }
  }

  @override
  void dispose() {
    widget.actions.releaseAll(_device);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.extent.isFinite || widget.extent < 64 || widget.extent > 240) {
      throw ArgumentError('Touch pad extent must be 64..240 logical pixels.');
    }
    return Focus(
      onFocusChange: (focus) {
        if (!focus) _cancel();
      },
      onKeyEvent: (_, event) {
        final arrows = {
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        };
        if (!arrows.contains(event.logicalKey)) return KeyEventResult.ignored;
        if (event is KeyUpEvent) {
          _keys.remove(event.logicalKey);
        } else {
          _keys.add(event.logicalKey);
        }
        _publish();
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onPanStart: (event) => _move(event.localPosition),
        onPanUpdate: (event) => _move(event.localPosition),
        onPanEnd: (_) {
          _pointer = Offset.zero;
          _publish();
        },
        onPanCancel: () {
          _pointer = Offset.zero;
          _publish();
        },
        child: SizedBox.square(
          dimension: widget.extent,
          child: Stack(
            alignment: Alignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: SizedBox.square(dimension: widget.extent),
              ),
              Transform.translate(
                offset: Offset(_value.dx, -_value.dy) * widget.extent * .3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  child: const SizedBox.square(dimension: 24),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: '${widget.label} horizontal',
                      slider: true,
                      value: _value.dx.toStringAsFixed(1),
                      increasedValue: (_value.dx + .1)
                          .clamp(-1.0, 1.0)
                          .toStringAsFixed(1),
                      decreasedValue: (_value.dx - .1)
                          .clamp(-1.0, 1.0)
                          .toStringAsFixed(1),
                      onIncrease: () {
                        _pointer = Offset(
                          (_pointer.dx + .1).clamp(-1.0, 1.0),
                          _pointer.dy,
                        );
                        _publish();
                      },
                      onDecrease: () {
                        _pointer = Offset(
                          (_pointer.dx - .1).clamp(-1.0, 1.0),
                          _pointer.dy,
                        );
                        _publish();
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: Semantics(
                      label: '${widget.label} vertical',
                      slider: true,
                      value: _value.dy.toStringAsFixed(1),
                      increasedValue: (_value.dy + .1)
                          .clamp(-1.0, 1.0)
                          .toStringAsFixed(1),
                      decreasedValue: (_value.dy - .1)
                          .clamp(-1.0, 1.0)
                          .toStringAsFixed(1),
                      onIncrease: () {
                        _pointer = Offset(
                          _pointer.dx,
                          (_pointer.dy + .1).clamp(-1.0, 1.0),
                        );
                        _publish();
                      },
                      onDecrease: () {
                        _pointer = Offset(
                          _pointer.dx,
                          (_pointer.dy - .1).clamp(-1.0, 1.0),
                        );
                        _publish();
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
