part of '../zyren_interaction.dart';

enum ObjectPointerPhase {
  enter,
  leave,
  down,
  move,
  up,
  cancel,
  hover,
  tap,
  scroll,
  gotCapture,
  lostCapture,
}

typedef ObjectPointerHandler = void Function(ObjectPointerEvent event);

/// One callback in a child-to-parent dispatch. [hit] is the latest actual
/// intersection, or the capture's original intersection when dragging outside.
final class ObjectPointerEvent {
  final ObjectPointerPhase phase;
  final ScenePointerEvent source;
  final Object3D target, currentTarget;
  final PickResult hit;
  final bool captured;
  final SceneInteractionRouter _router;
  final _Dispatch _dispatch;
  final _Binding _binding;
  bool _active = true;
  ObjectPointerEvent._(
    this._router,
    this._dispatch,
    this._binding,
    this.phase,
    this.source,
    this.target,
    this.hit,
    this.captured,
  ) : currentTarget = _binding.object;

  /// Stops only this object's ancestor dispatch, not other input consumers.
  void stopPropagation() => _dispatch.stopped = true;

  /// Captures for [currentTarget]. Call during an active down or move callback.
  void capturePointer() {
    if (!_active ||
        (phase != ObjectPointerPhase.down &&
            phase != ObjectPointerPhase.move)) {
      throw StateError('Capture requires a live down or move callback.');
    }
    _router._capture(_binding, source, hit);
  }

  void releasePointer() {
    if (!_active) throw StateError('This callback has ended.');
    _router.releasePointer(source.pointer, owner: currentTarget);
  }
}

/// Object event routing for one scene. Dispose it after the host disconnects.
/// Picking uses visible triangle surfaces, with the nearest surface occluding
/// farther objects even when it has no registered handler.
final class SceneInteractionRouter {
  final Scene scene;
  late final SceneObjectFocus focus;
  final Camera Function() camera;
  final ViewportMetrics Function() viewport;
  final void Function(Object error, StackTrace stack)? onError;
  final Raycaster _raycaster;
  final _bindings = <Object3D, _Binding>{};
  final _hover = <int, _Route>{}, _captures = <int, _Route>{};
  final _pressed = <int, ScenePointerEvent>{};
  late final StreamSubscription<int> _sceneChanges;
  Registration? _connection;
  bool _disposed = false, _dispatching = false, _resetting = false;

  SceneInteractionRouter({
    required this.scene,
    required this.camera,
    required this.viewport,
    this.onError,
    Raycaster? raycaster,
  }) : _raycaster = raycaster ?? Raycaster() {
    focus = SceneObjectFocus(scene);
    _sceneChanges = scene.changes.listen((_) => _prune());
  }

  bool get isDisposed => _disposed;
  List<Object3D> get registeredObjects => List.unmodifiable(_bindings.keys);
  Map<int, Object3D> get hoveredObjects => Map.unmodifiable(
    _hover.map((pointer, route) => MapEntry(pointer, route.binding.object)),
  );
  Map<int, Object3D> get capturedObjects => Map.unmodifiable(
    _captures.map((pointer, route) => MapEntry(pointer, route.binding.object)),
  );
  Object3D? capturedObject(int pointer) => _captures[pointer]?.binding.object;
  Object3D? hoveredObject(int pointer) => _hover[pointer]?.binding.object;

  Registration register(Object3D object, ObjectPointerHandler handler) {
    _checkOpen();
    if (!_member(object)) {
      throw ArgumentError('Object must belong to this scene.');
    }
    if (_bindings.containsKey(object)) {
      throw StateError('This object already has an interaction handler.');
    }
    final binding = _Binding(object, handler);
    _bindings[object] = binding;
    return binding.registration = Registration(() => _remove(binding));
  }

  /// Connects one input source. Interests last only as long as the connection.
  /// Raw pointer observation works with an empty gesture set. Request drag only
  /// when this view should claim Flutter's gesture arena against scroll parents.
  Registration connect(
    InputSource input, {
    Set<SceneGesture> gestures = const {SceneGesture.tap},
  }) {
    _checkOpen();
    if (_connection != null) throw StateError('Input is already connected.');
    final scope = AttachmentScope();
    try {
      if (input is KeyboardInputSource) scope.keep(focus.connect(input));
      for (final gesture in gestures) {
        scope.keep(input.registerGesture(gesture));
      }
      scope.keep(
        InputRouter.forSource(input).register(
          id: 'zyren.interaction',
          priority: InputPriority.objects,
          claims: (event) =>
              !_disposed &&
              (event.phase == ScenePointerPhase.down ||
                  event.phase == ScenePointerPhase.tap) &&
              (event.buttons == 0 || event.buttons == 1) &&
              _pick(event) != null,
          onEvent: dispatch,
        ),
      );
    } catch (_) {
      scope.close();
      rethrow;
    }
    late Registration connection;
    connection = Registration(() {
      if (!identical(_connection, connection)) return;
      _connection = null;
      try {
        scope.close();
      } finally {
        reset();
      }
    });
    return _connection = connection;
  }

  void dispatch(ScenePointerEvent source) {
    _checkOpen();
    if (_dispatching || _resetting) {
      throw StateError('Input dispatch is reentrant.');
    }
    if (!source.point.x.isFinite || !source.point.y.isFinite) {
      throw ArgumentError('Pointer coordinates must be finite.');
    }
    final phase = switch (source.phase) {
      ScenePointerPhase.down => ObjectPointerPhase.down,
      ScenePointerPhase.move => ObjectPointerPhase.move,
      ScenePointerPhase.up => ObjectPointerPhase.up,
      ScenePointerPhase.cancel => ObjectPointerPhase.cancel,
      ScenePointerPhase.hover => ObjectPointerPhase.hover,
      ScenePointerPhase.tap => ObjectPointerPhase.tap,
      ScenePointerPhase.scroll => ObjectPointerPhase.scroll,
      _ => null,
    };
    if (phase == null) return;
    _dispatching = true;
    try {
      _prune();
      if (_disposed) return;
      final pointer = source.pointer;
      if (phase == ObjectPointerPhase.down) {
        _cancel(pointer);
        _pressed[pointer] = source;
      } else if (_pressed.containsKey(pointer)) {
        _pressed[pointer] = source;
      }
      final terminal =
          phase == ObjectPointerPhase.up || phase == ObjectPointerPhase.cancel;
      // Clear the active press before callbacks so a terminal event cannot recapture.
      if (terminal) _pressed.remove(pointer);
      final hit = phase == ObjectPointerPhase.cancel ? null : _pick(source);
      if (phase == ObjectPointerPhase.hover ||
          phase == ObjectPointerPhase.move ||
          phase == ObjectPointerPhase.down) {
        _updateHover(pointer, hit, source);
      }
      if (_disposed) return;
      final capture = _captures[pointer];
      final route = capture ?? hit;
      if (phase == ObjectPointerPhase.down && route != null) {
        focus.request(route.binding.object);
      }
      if (capture != null) capture.source = source;
      try {
        if (route != null && _live(route)) {
          _emit(route, phase, source, captured: capture != null);
        }
      } finally {
        if (terminal) {
          releasePointer(pointer);
          if (phase == ObjectPointerPhase.cancel ||
              source.kind != ScenePointerKind.mouse) {
            _leave(pointer, source);
          } else {
            _updateHover(pointer, hit, source);
          }
        }
      }
    } finally {
      _dispatching = false;
      _prune();
    }
  }

  _Route? _pick(ScenePointerEvent source) {
    final size = viewport();
    if (!size.isUsable) return null;
    final hit = _raycaster
        .captureFromCamera(
          scene,
          camera(),
          source.point,
          logicalWidth: size.width,
          logicalHeight: size.height,
        )
        .intersectFirst();
    if (hit == null) return null;
    for (Object3D? node = hit.object; node != null; node = node.parent) {
      final binding = _bindings[node];
      if (binding != null) return _Route(binding, hit, source);
    }
    return null;
  }

  bool _member(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (identical(node, scene)) return true;
    }
    return false;
  }

  bool _visible(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (!node.visible) return false;
    }
    return true;
  }

  bool _descendsFrom(Object3D object, Object3D ancestor) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (identical(node, ancestor)) return true;
    }
    return false;
  }

  bool _live(_Route route) =>
      !_disposed &&
      route.binding.active &&
      _member(route.binding.object) &&
      _member(route.hit.object) &&
      _descendsFrom(route.hit.object, route.binding.object) &&
      _visible(route.binding.object) &&
      _visible(route.hit.object);

  void _updateHover(int pointer, _Route? next, ScenePointerEvent source) {
    final old = _hover[pointer];
    if (old?.binding == next?.binding) {
      if (next != null) _hover[pointer] = next;
      return;
    }
    _leave(pointer, source);
    if (next != null && _live(next)) {
      _hover[pointer] = next;
      _emit(next, ObjectPointerPhase.enter, source, cleanup: true);
    }
  }

  void _leave(int pointer, ScenePointerEvent source) {
    final old = _hover.remove(pointer);
    if (old != null) {
      _emit(old, ObjectPointerPhase.leave, source, cleanup: true);
    }
  }

  /// Call from the host's viewport-exit callback. Capture remains active.
  void clearHover([int? pointer]) {
    for (final id in pointer == null ? _hover.keys.toList() : [pointer]) {
      final route = _hover[id];
      if (route != null) _leave(id, route.source);
    }
  }

  void _capture(_Binding binding, ScenePointerEvent source, PickResult hit) {
    _checkOpen();
    if (_resetting ||
        !_pressed.containsKey(source.pointer) ||
        !binding.active ||
        !_member(binding.object) ||
        !_member(hit.object)) {
      throw StateError('Capture requires an active pointer and scene target.');
    }
    if (_captures[source.pointer]?.binding == binding) return;
    releasePointer(source.pointer);
    final route = _Route(binding, hit, source);
    if (!_live(route) || !_pressed.containsKey(source.pointer)) return;
    _captures[source.pointer] = route;
    _emit(
      route,
      ObjectPointerPhase.gotCapture,
      source,
      captured: true,
      cleanup: true,
    );
  }

  void releasePointer(int pointer, {Object3D? owner}) {
    final route = _captures[pointer];
    if (route == null ||
        (owner != null && !identical(owner, route.binding.object))) {
      return;
    }
    _captures.remove(pointer);
    _emit(
      route,
      ObjectPointerPhase.lostCapture,
      route.source,
      captured: true,
      cleanup: true,
    );
  }

  void _cancel(int pointer) {
    _pressed.remove(pointer);
    final route = _captures.remove(pointer);
    if (route == null) return;
    _emit(
      route,
      ObjectPointerPhase.cancel,
      route.source,
      captured: true,
      cleanup: true,
    );
    _emit(
      route,
      ObjectPointerPhase.lostCapture,
      route.source,
      captured: true,
      cleanup: true,
    );
  }

  void _emit(
    _Route route,
    ObjectPointerPhase phase,
    ScenePointerEvent source, {
    bool captured = false,
    bool cleanup = false,
  }) {
    final dispatch = _Dispatch();
    final path = <_Binding>[route.binding];
    // Cleanup is direct to its former target. Removed ancestors must not receive
    // events through a route which no longer exists in the scene graph.
    if (!cleanup) {
      for (
        var parent = route.binding.object.parent;
        parent != null;
        parent = parent.parent
      ) {
        final binding = _bindings[parent];
        if (binding != null) path.add(binding);
      }
    }
    for (final binding in path) {
      if (!cleanup &&
          (!_live(route) ||
              !binding.active ||
              !_member(binding.object) ||
              !_descendsFrom(route.binding.object, binding.object))) {
        break;
      }
      final event = ObjectPointerEvent._(
        this,
        dispatch,
        binding,
        phase,
        source,
        route.binding.object,
        route.hit,
        captured,
      );
      try {
        binding.handler(event);
      } catch (error, stack) {
        if (onError case final report?) {
          report(error, stack);
        } else {
          Zone.current.handleUncaughtError(error, stack);
        }
      } finally {
        event._active = false;
      }
      if (dispatch.stopped) break;
    }
  }

  void _remove(_Binding binding) {
    if (!binding.active) return;
    binding.active = false;
    _bindings.remove(binding.object);
    for (final entry in _captures.entries.toList()) {
      if (entry.value.binding == binding) _cancel(entry.key);
    }
    for (final entry in _hover.entries.toList()) {
      if (entry.value.binding == binding) _leave(entry.key, entry.value.source);
    }
  }

  void _prune() {
    if (_disposed) return;
    for (final binding in _bindings.values.toList()) {
      if (!_member(binding.object)) binding.registration.dispose();
    }
    for (final entry in _captures.entries.toList()) {
      if (!_live(entry.value)) _cancel(entry.key);
    }
    for (final entry in _hover.entries.toList()) {
      if (!_live(entry.value)) _leave(entry.key, entry.value.source);
    }
  }

  /// Cancels pointer state while preserving registered objects for reconnection.
  void reset() {
    if (_resetting) return;
    _resetting = true;
    try {
      focus.blur();
      _pressed.clear();
      for (final pointer in _captures.keys.toList()) {
        _cancel(pointer);
      }
      clearHover();
    } finally {
      _resetting = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connection?.dispose();
    reset();
    for (final binding in _bindings.values.toList()) {
      binding.registration.dispose();
    }
    unawaited(_sceneChanges.cancel());
    focus.dispose();
    _raycaster.clearCache();
  }

  void _checkOpen() {
    if (_disposed) throw StateError('Interaction router has been disposed.');
  }
}

final class _Binding {
  final Object3D object;
  final ObjectPointerHandler handler;
  late final Registration registration;
  bool active = true;
  _Binding(this.object, this.handler);
}

final class _Route {
  final _Binding binding;
  final PickResult hit;
  ScenePointerEvent source;
  _Route(this.binding, this.hit, this.source);
}

final class _Dispatch {
  bool stopped = false;
}
