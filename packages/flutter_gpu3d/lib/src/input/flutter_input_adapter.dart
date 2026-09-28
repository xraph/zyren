import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/gpu3d.dart';

typedef ScenePointerCallback = void Function(ScenePointerEvent event);

/// One controller's input. Events are published only by its attached view.
class FlutterInputAdapter implements ViewportInputSource {
  final _events = StreamController<ScenePointerEvent>.broadcast();
  final _interests = <SceneGesture, int>{};
  VoidCallback? onInterestsChanged;
  bool _closed = false, _active = true;
  @override
  double logicalWidth = 0;
  @override
  double logicalHeight = 0;
  final _pointers = <int, PointerEvent>{};
  ScenePointerKind _gestureKind = ScenePointerKind.unknown;
  int _gestureButtons = 0;
  void setActive(bool value) {
    if (_active == value || _closed) return;
    if (!value) {
      emit(
        ScenePointerEvent(
          point: const ViewportPoint(0, 0),
          phase: ScenePointerPhase.cancel,
        ),
        null,
      );
      _pointers.clear();
    }
    _active = value;
  }

  @override
  Stream<ScenePointerEvent> get events => _events.stream;
  bool wants(SceneGesture gesture) => (_interests[gesture] ?? 0) > 0;
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
    if (_closed || !_active) return;
    _events.add(event);
    callback?.call(event);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _interests.clear();
    onInterestsChanged = null;
    unawaited(_events.close());
  }

  static Set<SceneModifier> get modifiers => {
    if (HardwareKeyboard.instance.isShiftPressed) SceneModifier.shift,
    if (HardwareKeyboard.instance.isControlPressed) SceneModifier.control,
    if (HardwareKeyboard.instance.isAltPressed) SceneModifier.alt,
    if (HardwareKeyboard.instance.isMetaPressed) SceneModifier.meta,
  };
  static ScenePointerKind _kind(PointerDeviceKind kind) => switch (kind) {
    PointerDeviceKind.touch => ScenePointerKind.touch,
    PointerDeviceKind.mouse => ScenePointerKind.mouse,
    PointerDeviceKind.stylus => ScenePointerKind.stylus,
    PointerDeviceKind.invertedStylus => ScenePointerKind.invertedStylus,
    PointerDeviceKind.trackpad => ScenePointerKind.trackpad,
    PointerDeviceKind.unknown => ScenePointerKind.unknown,
  };
  ScenePointerEvent convert(PointerEvent event, ScenePointerPhase phase) =>
      ScenePointerEvent(
        point: ViewportPoint(event.localPosition.dx, event.localPosition.dy),
        delta: ViewportPoint(event.localDelta.dx, event.localDelta.dy),
        phase: phase,
        pointer: event.pointer,
        buttons: event.buttons,
        kind: _kind(event.kind),
        time: event.timeStamp,
        modifiers: modifiers,
      );
  Widget wrap(Widget child, ScenePointerCallback? callback) {
    void pointer(PointerEvent event, ScenePointerPhase phase) {
      if (phase == ScenePointerPhase.down || phase == ScenePointerPhase.move) {
        _pointers[event.pointer] = event;
      }
      emit(convert(event, phase), callback);
      if (phase == ScenePointerPhase.up || phase == ScenePointerPhase.cancel) {
        _pointers.remove(event.pointer);
      }
    }

    void gesture(
      ScenePointerPhase phase,
      Offset point, {
      Offset delta = Offset.zero,
      double scale = 1,
      double rotation = 0,
      int pointerCount = 1,
      Duration time = Duration.zero,
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
        time: time,
        modifiers: modifiers,
      ),
      callback,
    );
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => pointer(event, ScenePointerPhase.down),
      onPointerMove: (event) => pointer(event, ScenePointerPhase.move),
      onPointerUp: (event) => pointer(event, ScenePointerPhase.up),
      onPointerCancel: (event) => pointer(event, ScenePointerPhase.cancel),
      onPointerHover: (event) => pointer(event, ScenePointerPhase.hover),
      onPointerPanZoomStart: (event) => pointer(event, ScenePointerPhase.down),
      onPointerPanZoomUpdate: (event) => pointer(event, ScenePointerPhase.move),
      onPointerPanZoomEnd: (event) => pointer(event, ScenePointerPhase.up),
      onPointerSignal: (event) {
        if (!_active ||
            event is! PointerScrollEvent ||
            !wants(SceneGesture.scroll)) {
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
              kind: _kind(scroll.kind),
              time: scroll.timeStamp,
              modifiers: modifiers,
            ),
            callback,
          );
        });
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (wants(SceneGesture.tap))
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (recognizer) =>
                      recognizer.onTapUp = (event) =>
                          gesture(ScenePointerPhase.tap, event.localPosition),
                ),
          if (wants(SceneGesture.scale))
            ScaleGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
                  () => ScaleGestureRecognizer(
                    allowedButtonsFilter: (buttons) =>
                        buttons == kPrimaryButton ||
                        buttons == kSecondaryButton ||
                        buttons == kMiddleMouseButton,
                  ),
                  (recognizer) => recognizer
                    ..onStart = (event) {
                      final pointer = _pointers.values.firstOrNull;
                      _gestureKind = _kind(
                        event.kind ??
                            pointer?.kind ??
                            PointerDeviceKind.unknown,
                      );
                      _gestureButtons = pointer?.buttons ?? 0;
                      gesture(
                        ScenePointerPhase.scaleStart,
                        event.localFocalPoint,
                        pointerCount: event.pointerCount,
                        time: event.sourceTimeStamp ?? Duration.zero,
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
                        time: event.sourceTimeStamp ?? Duration.zero,
                      );
                    }
                    ..onEnd = (event) => gesture(
                      ScenePointerPhase.scaleEnd,
                      Offset.zero,
                      pointerCount: event.pointerCount,
                    ),
                ),
        },
        child: child,
      ),
    );
  }
}
