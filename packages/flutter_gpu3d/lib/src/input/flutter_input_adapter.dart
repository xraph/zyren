import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/gpu3d.dart';

typedef ScenePointerCallback = void Function(ScenePointerEvent event);

/// One controller's input. Events are published only by its attached view.
class FlutterInputAdapter implements ViewportInputSource, KeyboardInputSource {
  final _events = StreamController<ScenePointerEvent>.broadcast();
  final _keys = StreamController<SceneKeyEvent>.broadcast();
  final _keyInterests = <SceneKey, int>{};
  final _pressedKeys = <SceneKey>{};
  final _activePointers = <int, ScenePointerEvent>{};
  PointerDownEvent? _dragTap;
  @override
  ViewportMetrics viewport = const ViewportMetrics(0, 0);
  @override
  Stream<SceneKeyEvent> get keyEvents => _keys.stream;
  final _interests = <SceneGesture, int>{};
  VoidCallback? onInterestsChanged;
  bool _closed = false;
  @override
  Stream<ScenePointerEvent> get events => _events.stream;
  bool wants(SceneGesture gesture) => (_interests[gesture] ?? 0) > 0;
  bool get wantsKeyboard => _keyInterests.values.any((count) => count > 0);
  @override
  Registration registerKeys(Set<SceneKey> keys) {
    if (_closed) throw StateError('Input has been closed.');
    final registered = Set<SceneKey>.of(keys);
    for (final key in registered) {
      _keyInterests.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
    onInterestsChanged?.call();
    return Registration(() {
      if (_closed) return;
      for (final key in registered) {
        _keyInterests.update(key, (count) => count - 1);
        if (_keyInterests[key] == 0 && _pressedKeys.remove(key)) {
          _keys.add(SceneKeyEvent(key, SceneKeyPhase.cancel));
        }
      }
      onInterestsChanged?.call();
    });
  }

  void cancelKeys() {
    if (_closed) return;
    for (final key in _pressedKeys) {
      _keys.add(SceneKeyEvent(key, SceneKeyPhase.cancel));
    }
    _pressedKeys.clear();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_closed || !node.hasPrimaryFocus) return KeyEventResult.ignored;
    final key = _keyMap[event.logicalKey];
    if (key == null || (_keyInterests[key] ?? 0) == 0) {
      return KeyEventResult.ignored;
    }
    final phase = event is KeyUpEvent
        ? SceneKeyPhase.up
        : event is KeyRepeatEvent
        ? SceneKeyPhase.repeat
        : SceneKeyPhase.down;
    if (phase == SceneKeyPhase.up) {
      _pressedKeys.remove(key);
    } else {
      _pressedKeys.add(key);
    }
    _keys.add(
      SceneKeyEvent(key, phase, modifiers: modifiers, time: event.timeStamp),
    );
    return KeyEventResult.handled;
  }

  static final _keyMap = <LogicalKeyboardKey, SceneKey>{
    LogicalKeyboardKey.arrowLeft: SceneKey.arrowLeft,
    LogicalKeyboardKey.arrowUp: SceneKey.arrowUp,
    LogicalKeyboardKey.arrowRight: SceneKey.arrowRight,
    LogicalKeyboardKey.arrowDown: SceneKey.arrowDown,
    LogicalKeyboardKey.keyW: SceneKey.w,
    LogicalKeyboardKey.keyA: SceneKey.a,
    LogicalKeyboardKey.keyS: SceneKey.s,
    LogicalKeyboardKey.keyD: SceneKey.d,
    LogicalKeyboardKey.keyQ: SceneKey.q,
    LogicalKeyboardKey.keyE: SceneKey.e,
    LogicalKeyboardKey.escape: SceneKey.escape,
    LogicalKeyboardKey.space: SceneKey.space,
  };
  @override
  Registration registerGesture(SceneGesture gesture) {
    if (_closed) throw StateError('Input has been closed.');
    _interests.update(gesture, (count) => count + 1, ifAbsent: () => 1);
    onInterestsChanged?.call();
    return Registration(() {
      if (_closed) return;
      _interests.update(gesture, (count) => count - 1);
      onInterestsChanged?.call();
    });
  }

  void emit(ScenePointerEvent event, ScenePointerCallback? callback) {
    if (_closed) return;
    switch (event.phase) {
      case ScenePointerPhase.down:
        _activePointers[event.pointer] = event;
      case ScenePointerPhase.move:
        if (_activePointers.containsKey(event.pointer)) {
          _activePointers[event.pointer] = event;
        }
      case ScenePointerPhase.up:
      case ScenePointerPhase.cancel:
        _activePointers.remove(event.pointer);
      default:
        break;
    }
    _events.add(event);
    callback?.call(event);
  }

  void suspend() {
    _dragTap = null;
    cancelKeys();
    for (final event in _activePointers.values.toList()) {
      emit(
        ScenePointerEvent(
          point: event.point,
          pointer: event.pointer,
          kind: event.kind,
          phase: ScenePointerPhase.cancel,
        ),
        null,
      );
    }
  }

  void close() {
    if (_closed) return;
    suspend();
    _closed = true;
    _interests.clear();
    _keyInterests.clear();
    onInterestsChanged = null;
    unawaited(_events.close());
    unawaited(_keys.close());
  }

  static Set<SceneModifier> get modifiers => {
    if (HardwareKeyboard.instance.isShiftPressed) SceneModifier.shift,
    if (HardwareKeyboard.instance.isControlPressed) SceneModifier.control,
    if (HardwareKeyboard.instance.isAltPressed) SceneModifier.alt,
    if (HardwareKeyboard.instance.isMetaPressed) SceneModifier.meta,
  };
  ScenePointerEvent convert(PointerEvent event, ScenePointerPhase phase) =>
      ScenePointerEvent(
        point: ViewportPoint(event.localPosition.dx, event.localPosition.dy),
        delta: ViewportPoint(event.localDelta.dx, event.localDelta.dy),
        phase: phase,
        pointer: event.pointer,
        buttons: event.buttons,
        kind: switch (event.kind) {
          PointerDeviceKind.touch => ScenePointerKind.touch,
          PointerDeviceKind.mouse => ScenePointerKind.mouse,
          PointerDeviceKind.stylus => ScenePointerKind.stylus,
          PointerDeviceKind.invertedStylus => ScenePointerKind.invertedStylus,
          PointerDeviceKind.trackpad => ScenePointerKind.trackpad,
          PointerDeviceKind.unknown => ScenePointerKind.unknown,
        },
        time: event.timeStamp,
        modifiers: modifiers,
      );
  Widget wrap(Widget child, ScenePointerCallback? callback) {
    void pointer(PointerEvent event, ScenePointerPhase phase) {
      // The eager drag recognizer owns the arena, so Flutter's tap recognizer
      // cannot win there. Recognize a single stationary primary pointer here.
      final rawTap = wants(SceneGesture.pointerDrag) && wants(SceneGesture.tap);
      var tapped = false;
      if (event is PointerDownEvent) {
        _dragTap =
            rawTap && _activePointers.isEmpty && event.buttons == kPrimaryButton
            ? event
            : null;
      } else if (_dragTap case final start?) {
        if (!rawTap ||
            event.pointer != start.pointer ||
            phase == ScenePointerPhase.cancel ||
            (event.localPosition - start.localPosition).distance >
                computeHitSlop(event.kind, null)) {
          _dragTap = null;
        } else if (phase == ScenePointerPhase.up) {
          tapped = true;
          _dragTap = null;
        }
      }
      emit(convert(event, phase), callback);
      if (tapped) emit(convert(event, ScenePointerPhase.tap), callback);
    }

    void gesture(
      ScenePointerPhase phase,
      Offset point, {
      Offset delta = Offset.zero,
      double scale = 1,
      double rotation = 0,
    }) => emit(
      ScenePointerEvent(
        point: ViewportPoint(point.dx, point.dy),
        phase: phase,
        delta: ViewportPoint(delta.dx, delta.dy),
        scale: scale,
        rotation: rotation,
        modifiers: modifiers,
      ),
      callback,
    );
    return Focus(
      canRequestFocus: wantsKeyboard,
      onFocusChange: (focused) {
        if (!focused) cancelKeys();
      },
      onKeyEvent: _key,
      child: Builder(
        builder: (context) => Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (wantsKeyboard) Focus.of(context).requestFocus();
            pointer(event, ScenePointerPhase.down);
          },
          onPointerMove: (event) => pointer(event, ScenePointerPhase.move),
          onPointerUp: (event) => pointer(event, ScenePointerPhase.up),
          onPointerCancel: (event) => pointer(event, ScenePointerPhase.cancel),
          onPointerHover: (event) => pointer(event, ScenePointerPhase.hover),
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || !wants(SceneGesture.scroll)) {
              return;
            }
            GestureBinding.instance.pointerSignalResolver.register(event, (
              resolved,
            ) {
              final scroll = resolved as PointerScrollEvent;
              emit(
                ScenePointerEvent(
                  point: ViewportPoint(
                    scroll.localPosition.dx,
                    scroll.localPosition.dy,
                  ),
                  delta: ViewportPoint(
                    scroll.scrollDelta.dx,
                    scroll.scrollDelta.dy,
                  ),
                  phase: ScenePointerPhase.scroll,
                  kind: ScenePointerKind.mouse,
                  time: scroll.timeStamp,
                  modifiers: modifiers,
                ),
                callback,
              );
            });
          },
          child: RawGestureDetector(
            gestures: {
              if (wants(SceneGesture.pointerDrag))
                EagerGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      EagerGestureRecognizer
                    >(EagerGestureRecognizer.new, (_) {}),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp:
                  wants(SceneGesture.tap) && !wants(SceneGesture.pointerDrag)
                  ? (event) =>
                        gesture(ScenePointerPhase.tap, event.localPosition)
                  : null,
              onScaleStart: wants(SceneGesture.scale)
                  ? (event) => gesture(
                      ScenePointerPhase.scaleStart,
                      event.localFocalPoint,
                    )
                  : null,
              onScaleUpdate: wants(SceneGesture.scale)
                  ? (event) => gesture(
                      ScenePointerPhase.scaleUpdate,
                      event.localFocalPoint,
                      delta: event.focalPointDelta,
                      scale: event.scale,
                      rotation: event.rotation,
                    )
                  : null,
              onScaleEnd: wants(SceneGesture.scale)
                  ? (_) => gesture(ScenePointerPhase.scaleEnd, Offset.zero)
                  : null,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
