import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/gpu3d.dart';

typedef ScenePointerCallback = void Function(ScenePointerEvent event);

/// One controller's input. Events are published only by its attached view.
class FlutterInputAdapter implements InputSource {
  final _events = StreamController<ScenePointerEvent>.broadcast();
  final _interests = <SceneGesture, int>{};
  VoidCallback? onInterestsChanged;
  bool _closed = false;
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
    if (_closed) return;
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
    void pointer(PointerEvent event, ScenePointerPhase phase) =>
        emit(convert(event, phase), callback);
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
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => pointer(event, ScenePointerPhase.down),
      onPointerMove: (event) => pointer(event, ScenePointerPhase.move),
      onPointerUp: (event) => pointer(event, ScenePointerPhase.up),
      onPointerCancel: (event) => pointer(event, ScenePointerPhase.cancel),
      onPointerHover: (event) => pointer(event, ScenePointerPhase.hover),
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || !wants(SceneGesture.scroll)) return;
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: wants(SceneGesture.tap)
            ? (event) => gesture(ScenePointerPhase.tap, event.localPosition)
            : null,
        onScaleStart: wants(SceneGesture.scale)
            ? (event) =>
                  gesture(ScenePointerPhase.scaleStart, event.localFocalPoint)
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
    );
  }
}
