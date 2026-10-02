import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';

typedef ScenePointerCallback = void Function(ScenePointerEvent event);

/// One controller's input. Events are published only by its attached view.
class FlutterInputAdapter implements ViewportInputSource, KeyboardInputSource {
  double get logicalWidth => viewport.width;
  set logicalWidth(double value) =>
      viewport = ViewportMetrics(value, viewport.height);
  double get logicalHeight => viewport.height;
  set logicalHeight(double value) =>
      viewport = ViewportMetrics(viewport.width, value);
  ScenePointerKind _gestureKind = ScenePointerKind.unknown;
  int _gestureButtons = 0;
  bool _active = true;
  void setActive(bool value) {
    if (!value && _active) suspend();
    _active = value;
  }

  final _events = StreamController<ScenePointerEvent>.broadcast();
  final _keys = StreamController<SceneKeyEvent>.broadcast();
  final _keyInterests = <SceneKey, int>{};
  final _pressedKeys = <SceneKey>{};
  final _activePointers = <int, ScenePointerEvent>{};
  final _trackpads = <int, _TrackpadMotion>{};
  Ticker? _coastTicker;
  PointerEvent? _coastSource;
  ScenePointerCallback? _coastCallback;
  double _coastVelocity = 0;
  Duration _coastElapsed = Duration.zero, _coastStart = Duration.zero;
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
    if (_closed || !_active || !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
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
      if (gesture == SceneGesture.scroll && !wants(SceneGesture.scroll)) {
        _cancelTrackpads();
      }
      onInterestsChanged?.call();
    });
  }

  void emit(ScenePointerEvent event, ScenePointerCallback? callback) {
    if (_closed || !_active) return;
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
    _cancelTrackpads();
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

  void _cancelTrackpad(int pointer, ScenePointerCallback? callback) {
    if (_coastSource?.pointer == pointer) _stopCoast(cancel: true);
    final previous = _trackpads.remove(pointer);
    if (previous == null) return;
    emit(convert(previous.event, ScenePointerPhase.cancel), callback);
  }

  void _cancelTrackpads() {
    _stopCoast(cancel: true);
    for (final pointer in _trackpads.keys.toList()) {
      _cancelTrackpad(pointer, null);
    }
  }

  void _trackpad(PointerEvent event, ScenePointerCallback? callback) {
    if (_closed || !wants(SceneGesture.scroll)) return;
    if (event is PointerPanZoomStartEvent) {
      _stopCoast(cancel: true);
      _trackpads[event.pointer] = _TrackpadMotion(event);
    } else if (event is PointerPanZoomEndEvent) {
      final motion = _trackpads.remove(event.pointer);
      if (motion == null || _trackpads.isNotEmpty) return;
      final velocity = motion.releaseVelocity(event.timeStamp);
      if (velocity.abs() < 30) return;
      _stopCoast();
      _coastSource = motion.event;
      _coastCallback = callback;
      _coastVelocity = velocity.clamp(-3200, 3200);
      _coastElapsed = Duration.zero;
      _coastStart = event.timeStamp;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_interruptCoast);
      (_coastTicker ??= Ticker(
        _tickCoast,
        debugLabel: 'Scene trackpad zoom',
      )).start();
    } else if (event is PointerPanZoomUpdateEvent) {
      final previous = _trackpads[event.pointer];
      if (previous == null || !event.scale.isFinite || event.scale <= 0) return;
      // Native scale is cumulative. Convert each ratio to wheel-equivalent
      // logical pixels, inverse to Flutter's default scroll-to-scale factor.
      final pinch = -200 * (math.log(event.scale) - math.log(previous.scale));
      final delta = -event.localPanDelta + Offset(0, pinch);
      previous.update(event, delta.dy);
      if (delta == Offset.zero) return;
      _emitTrackpad(event, delta, callback);
    }
  }

  void _emitTrackpad(
    PointerEvent event,
    Offset delta,
    ScenePointerCallback? callback, {
    Duration? time,
  }) => emit(
    ScenePointerEvent(
      point: ViewportPoint(event.localPosition.dx, event.localPosition.dy),
      delta: ViewportPoint(delta.dx, delta.dy),
      phase: ScenePointerPhase.scroll,
      pointer: event.pointer,
      kind: ScenePointerKind.trackpad,
      time: time ?? event.timeStamp,
      modifiers: modifiers,
    ),
    callback,
  );

  void _tickCoast(Duration elapsed) {
    final source = _coastSource;
    if (source == null || _closed || !wants(SceneGesture.scroll)) {
      _stopCoast();
      return;
    }
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final previous =
        _coastElapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= previous) return;
    // Integrate exponential velocity exactly over each display frame. Travel
    // stays independent of refresh rate, with at most 400 extra logical pixels.
    final decay = math.exp(-8 * seconds);
    final distance = _coastVelocity * (math.exp(-8 * previous) - decay) / 8;
    _coastElapsed = elapsed;
    _emitTrackpad(
      source,
      Offset(0, distance),
      _coastCallback,
      time: _coastStart + elapsed,
    );
    if ((_coastVelocity * decay).abs() < 5) _stopCoast();
  }

  void _stopCoast({bool cancel = false}) {
    final source = _coastSource;
    if (source != null) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_interruptCoast);
    }
    _coastSource = null;
    _coastCallback = null;
    _coastTicker?.stop();
    if (cancel && source != null) {
      emit(convert(source, ScenePointerPhase.cancel), null);
    }
  }

  void _interruptCoast(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerPanZoomStartEvent ||
        event is PointerScrollEvent ||
        event is PointerScrollInertiaCancelEvent) {
      _stopCoast(cancel: true);
    }
  }

  void close() {
    if (_closed) return;
    suspend();
    _coastTicker?.dispose();
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
        _gestureKind = convert(event, phase).kind;
        _gestureButtons = event.buttons;
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
      int pointerCount = 0,
    }) => emit(
      ScenePointerEvent(
        point: ViewportPoint(point.dx, point.dy),
        phase: phase,
        delta: ViewportPoint(delta.dx, delta.dy),
        scale: scale,
        rotation: rotation,
        pointerCount: pointerCount,
        kind: _gestureKind,
        buttons: _gestureButtons,
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
          onPointerPanZoomStart: (_) {
            _gestureKind = ScenePointerKind.trackpad;
            _gestureButtons = 0;
          },
          onPointerDown: (event) {
            _stopCoast(cancel: true);
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
              _stopCoast(cancel: true);
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
              if (wants(SceneGesture.scale))
                ScaleGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      ScaleGestureRecognizer
                    >(
                      () => ScaleGestureRecognizer(
                        allowedButtonsFilter: (buttons) =>
                            buttons == kPrimaryButton ||
                            buttons == kSecondaryButton ||
                            buttons == kMiddleMouseButton,
                      ),
                      (recognizer) {
                        recognizer
                          ..onStart = (event) {
                            gesture(
                              ScenePointerPhase.scaleStart,
                              event.localFocalPoint,
                              pointerCount: event.pointerCount,
                            );
                          }
                          ..onUpdate = (event) {
                            gesture(
                              ScenePointerPhase.scaleUpdate,
                              event.localFocalPoint,
                              delta: event.focalPointDelta,
                              scale: event.scale,
                              rotation: event.rotation,
                              pointerCount: event.pointerCount,
                            );
                          }
                          ..onEnd = (event) {
                            gesture(
                              ScenePointerPhase.scaleEnd,
                              Offset.zero,
                              pointerCount: event.pointerCount,
                            );
                          };
                      },
                    ),
              if (wants(SceneGesture.scroll) &&
                  (wants(SceneGesture.pointerDrag) ||
                      !wants(SceneGesture.scale)))
                _TrackpadZoomRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _TrackpadZoomRecognizer
                    >(_TrackpadZoomRecognizer.new, (recognizer) {
                      recognizer.onEvent = (event) =>
                          _trackpad(event, callback);
                      recognizer.onCancel = (pointer) =>
                          _cancelTrackpad(pointer, callback);
                    }),
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
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackpadMotion {
  PointerEvent event;
  double scale = 1, _distance = 0, _direction = 0;
  final _samples = <({Duration time, double distance})>[];

  _TrackpadMotion(this.event) {
    _samples.add((time: event.timeStamp, distance: 0));
  }

  void update(PointerPanZoomUpdateEvent next, double delta) {
    if (next.timeStamp <= event.timeStamp ||
        (delta != 0 && _direction != 0 && delta.sign != _direction)) {
      _samples
        ..clear()
        ..add((time: event.timeStamp, distance: _distance));
    }
    if (delta != 0) _direction = delta.sign;
    _distance += delta;
    _samples.add((time: next.timeStamp, distance: _distance));
    final cutoff = next.timeStamp - const Duration(milliseconds: 80);
    while (_samples.length > 2 && _samples.first.time < cutoff) {
      _samples.removeAt(0);
    }
    event = next;
    scale = next.scale;
  }

  double releaseVelocity(Duration time) {
    final pause = time - event.timeStamp;
    if (pause.isNegative || pause > const Duration(milliseconds: 80)) return 0;
    final first = _samples.first, last = _samples.last;
    final seconds =
        (time - first.time).inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return (last.distance - first.distance) / seconds;
  }
}

// Claim only native pan/zoom sequences. Touch keeps its individual pointer
// stream, and scrollable ancestors retain trackpad input outside this scene.
class _TrackpadZoomRecognizer extends OneSequenceGestureRecognizer {
  _TrackpadZoomRecognizer()
    : super(supportedDevices: {PointerDeviceKind.trackpad});

  final _starts = <int, PointerPanZoomStartEvent>{};
  final _accepted = <int>{};
  void Function(PointerEvent event)? onEvent;
  void Function(int pointer)? onCancel;

  @override
  bool isPointerAllowed(PointerDownEvent event) => false;

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {}

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    _starts[event.pointer] = event;
    startTrackingPointer(event.pointer, event.transform);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  @override
  void acceptGesture(int pointer) {
    final start = _starts.remove(pointer);
    if (start == null) return;
    _accepted.add(pointer);
    onEvent?.call(start);
  }

  @override
  void rejectGesture(int pointer) {
    _starts.remove(pointer);
    if (_accepted.remove(pointer)) onCancel?.call(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_accepted.contains(event.pointer) &&
        (event is PointerPanZoomUpdateEvent ||
            event is PointerPanZoomEndEvent)) {
      onEvent?.call(event);
    }
    if (event is PointerPanZoomEndEvent) {
      _starts.remove(event.pointer);
      _accepted.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'scene trackpad zoom';

  @override
  void dispose() {
    for (final pointer in _accepted.toList()) {
      onCancel?.call(pointer);
    }
    _accepted.clear();
    _starts.clear();
    super.dispose();
  }
}
