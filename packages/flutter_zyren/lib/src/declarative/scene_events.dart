part of 'scene_canvas.dart';

/// Current geometry is in [intersection]. Capture retains its original hit in
/// [captureIntersection], including when the pointer leaves that geometry.
/// Each object and ancestor receives one callback per dispatch. Instanced mesh
/// hits retain instanceIndex in [intersections]; dispatch deduplicates by object.
/// Mouse and stylus hover each use one cursor per kind across pointer ID changes.
/// Capture remains specific to the original pointer ID.
class SceneObjectEvent {
  final ScenePointerEvent pointerEvent;
  final PickResult? intersection, captureIntersection;
  final Object3D currentTarget;
  final List<PickResult> intersections;
  final Ray ray;
  final void Function() _capture, _release;
  bool _stopped = false;
  SceneObjectEvent._(
    this.pointerEvent,
    this.intersection,
    this.captureIntersection,
    this.currentTarget,
    this.intersections,
    this.ray,
    this._capture,
    this._release,
  );
  Object3D? get hitObject => intersection?.object;
  int get pointer => pointerEvent.pointer;
  void stopPropagation() => _stopped = true;
  void capturePointer() => _capture();
  void releasePointer() => _release();
}

enum _SceneDispatchPhase { enter, leave, down, move, up, cancel, click }

class _SceneEventDispatcher {
  final SceneController controller;
  final ScenePointerCallback missed;
  final bool Function() hasMissed;
  final _nodes = <Object3D, SceneNode>{};
  final _activePointers = <int>{};
  final _captures = <int, (Object3D, PickResult?)>{};
  final _hover = <int, Map<Object3D, PickResult>>{};
  final _routed = Expando<bool>();
  final _hoverStops = <int, (Object3D, Object?, bool)>{};
  final _lastHover = <int, ScenePointerEvent>{};
  Registration? _router, _interest, _tap;
  bool _syncPending = false;
  StreamSubscription<ScenePointerEvent>? _passive;
  bool _disposed = false;
  _SceneEventDispatcher(this.controller, this.missed, this.hasMissed) {
    _syncInterests();
    _router = InputRouter.forSource(controller.input).register(
      id: 'declarative-${identityHashCode(this)}',
      priority: InputPriority.objects,
      claims: (event) =>
          (event.phase == ScenePointerPhase.down ||
              event.phase == ScenePointerPhase.tap) &&
          _nodes.isNotEmpty &&
          _targets(_pick(event).$2).keys.any((target) {
            final node = _nodes[target]!;
            return _interactive(node);
          }),
      onEvent: (event) {
        if (event.phase == ScenePointerPhase.down) {
          _activePointers.add(event.pointer);
        }
        _routed[event] = true;
        try {
          _dispatch(event);
        } finally {
          if (event.phase == ScenePointerPhase.up ||
              event.phase == ScenePointerPhase.cancel) {
            _activePointers.remove(event.pointer);
            _captures.remove(event.pointer);
          }
        }
      },
    );
    _passive = controller.input.events.listen((event) {
      if (_disposed || InputRouter.forSource(controller.input).blocked) return;
      if (event.phase == ScenePointerPhase.tap &&
          _routed[event] != true &&
          _targets(_pick(event).$2).isEmpty) {
        missed(event);
      }
    });
  }
  bool _handles(SceneNode n) =>
      n.onTap != null ||
      n.onClick != null ||
      n.onPointerDown != null ||
      n.onPointerMove != null ||
      n.onPointerUp != null ||
      n.onPointerCancel != null ||
      n.onPointerEnter != null ||
      n.onPointerLeave != null;
  bool _interactive(SceneNode n) =>
      n.onTap != null ||
      n.onClick != null ||
      n.onPointerDown != null ||
      n.onPointerMove != null ||
      n.onPointerUp != null ||
      n.onPointerCancel != null;
  void set(Object3D object, SceneNode node) {
    if (_handles(node)) {
      _nodes[object] = node;
    } else {
      remove(object);
    }
    _syncInterests();
  }

  void _syncInterests() {
    if (_syncPending) return;
    _syncPending = true;
    scheduleMicrotask(() {
      _syncPending = false;
      if (_disposed || controller.isDisposed) return;
      final interactive = _nodes.values.any(_interactive);
      if (interactive) {
        _interest ??= controller.input.registerGesture(
          SceneGesture.pointerDrag,
        );
      } else {
        _interest?.dispose();
        _interest = null;
      }
      if (interactive || hasMissed()) {
        _tap ??= controller.input.registerGesture(SceneGesture.tap);
      } else {
        _tap?.dispose();
        _tap = null;
      }
    });
  }

  void remove(Object3D object) {
    _nodes.remove(object);
    _hoverStops.removeWhere((_, stop) => identical(stop.$1, object));
    _captures.removeWhere((_, c) => identical(c.$1, object));
    for (final hover in _hover.values) {
      hover.remove(object);
    }
    _syncInterests();
  }

  (Ray, List<PickResult>) _pick(ScenePointerEvent event) {
    final snapshot = controller.capturePick(event.point);
    return (snapshot.ray, List.unmodifiable(snapshot.intersectAll()));
  }

  Map<Object3D, PickResult> _targets(List<PickResult> hits) {
    final targets = <Object3D, PickResult>{};
    for (final hit in hits) {
      for (
        Object3D? object = hit.object;
        object != null;
        object = object.parent
      ) {
        if (_nodes.containsKey(object)) targets.putIfAbsent(object, () => hit);
      }
    }
    return targets;
  }

  void _dispatch(ScenePointerEvent event) {
    if (_disposed || controller.isDisposed) return;
    final hoverKey = switch (event.kind) {
      ScenePointerKind.mouse ||
      ScenePointerKind.stylus ||
      ScenePointerKind.invertedStylus => -1 - event.kind.index,
      _ => event.pointer,
    };
    final (ray, hits) = _pick(event);
    final targets = _targets(hits);
    if (event.phase == ScenePointerPhase.hover ||
        event.phase == ScenePointerPhase.move) {
      _lastHover[hoverKey] = event;
      final previous = _hover[hoverKey] ?? {};
      for (final entry in previous.entries.toList()) {
        if (!targets.containsKey(entry.key)) {
          _deliver(
            _SceneDispatchPhase.leave,
            event,
            entry.key,
            null,
            hits,
            ray,
          );
        }
      }
      var boundary = _hoverStops[hoverKey];
      if (boundary != null) {
        final node = _nodes[boundary.$1];
        final callback = boundary.$3
            ? node?.onPointerEnter
            : node?.onPointerMove;
        if (!targets.containsKey(boundary.$1) ||
            !identical(callback, boundary.$2)) {
          _hoverStops.remove(hoverKey);
          boundary = null;
        }
      }
      final entered = <Object3D, PickResult>{};
      for (final entry in targets.entries) {
        entered[entry.key] = entry.value;
        if (!previous.containsKey(entry.key) &&
            _deliver(
              _SceneDispatchPhase.enter,
              event,
              entry.key,
              entry.value,
              hits,
              ray,
            )) {
          _hoverStops[hoverKey] = (
            entry.key,
            _nodes[entry.key]?.onPointerEnter,
            true,
          );
          break;
        }
        if (identical(entry.key, boundary?.$1)) break;
      }
      for (final entry in previous.entries) {
        if (!entered.containsKey(entry.key) && targets.containsKey(entry.key)) {
          _deliver(
            _SceneDispatchPhase.leave,
            event,
            entry.key,
            null,
            hits,
            ray,
          );
        }
      }
      _hover[hoverKey] = entered;
      targets.removeWhere((target, _) => !entered.containsKey(target));
    }
    final capture = _captures[event.pointer];
    if (capture != null && capture.$2 != null) {
      for (
        Object3D? target = capture.$1;
        target != null;
        target = target.parent
      ) {
        if (_nodes.containsKey(target)) {
          targets.putIfAbsent(target, () => capture.$2!);
        }
      }
    }
    final phase = switch (event.phase) {
      ScenePointerPhase.down => _SceneDispatchPhase.down,
      ScenePointerPhase.move => _SceneDispatchPhase.move,
      ScenePointerPhase.up => _SceneDispatchPhase.up,
      ScenePointerPhase.cancel => _SceneDispatchPhase.cancel,
      ScenePointerPhase.tap => _SceneDispatchPhase.click,
      _ => null,
    };
    var moveStopped = false;
    if (phase != null) {
      for (final entry in targets.entries.toList()) {
        final hit = hits
            .where((h) => identical(h.object, entry.value.object))
            .firstOrNull;
        if (_deliver(phase, event, entry.key, hit, hits, ray)) {
          if (event.phase == ScenePointerPhase.move) {
            moveStopped = true;
            if (_hoverStops[hoverKey]?.$3 != true) {
              _hoverStops[hoverKey] = (
                entry.key,
                _nodes[entry.key]?.onPointerMove,
                false,
              );
            }
            final hovered = _hover[hoverKey];
            if (hovered != null && hovered.containsKey(entry.key)) {
              var blocked = false;
              for (final target in hovered.keys.toList()) {
                if (blocked) {
                  hovered.remove(target);
                  _deliver(
                    _SceneDispatchPhase.leave,
                    event,
                    target,
                    null,
                    hits,
                    ray,
                  );
                }
                if (identical(target, entry.key)) blocked = true;
              }
            }
          }
          break;
        }
      }
    }
    if (event.phase == ScenePointerPhase.move &&
        !moveStopped &&
        _hoverStops[hoverKey]?.$3 == false) {
      _hoverStops.remove(hoverKey);
    }
    if (event.phase == ScenePointerPhase.up ||
        event.phase == ScenePointerPhase.cancel) {
      _captures.remove(event.pointer);
      if (event.phase == ScenePointerPhase.cancel ||
          event.kind == ScenePointerKind.touch) {
        final previous = _hover.remove(hoverKey);
        _lastHover.remove(hoverKey);
        _hoverStops.remove(hoverKey);
        for (final entry
            in previous?.entries ?? <MapEntry<Object3D, PickResult>>[]) {
          _deliver(
            _SceneDispatchPhase.leave,
            event,
            entry.key,
            null,
            hits,
            ray,
          );
        }
      }
    }
  }

  bool _deliver(
    _SceneDispatchPhase phase,
    ScenePointerEvent raw,
    Object3D target,
    PickResult? hit,
    List<PickResult> hits,
    Ray ray,
  ) {
    final node = _nodes[target];
    if (node == null || _disposed) return false;
    final event = SceneObjectEvent._(
      raw,
      hit,
      _captures[raw.pointer]?.$2,
      target,
      hits,
      ray,
      () {
        if (!_disposed &&
            _nodes.containsKey(target) &&
            _activePointers.contains(raw.pointer)) {
          _captures[raw.pointer] = (target, hit ?? _captures[raw.pointer]?.$2);
        }
      },
      () => _captures.remove(raw.pointer),
    );
    final callback = switch (phase) {
      _SceneDispatchPhase.enter => node.onPointerEnter,
      _SceneDispatchPhase.leave => node.onPointerLeave,
      _SceneDispatchPhase.down => node.onPointerDown,
      _SceneDispatchPhase.move => node.onPointerMove,
      _SceneDispatchPhase.up => node.onPointerUp,
      _SceneDispatchPhase.cancel => node.onPointerCancel,
      _SceneDispatchPhase.click => node.onClick,
    };
    callback?.call(event);
    if (phase == _SceneDispatchPhase.click &&
        !event._stopped &&
        hit != null &&
        _nodes.containsKey(target)) {
      _nodes[target]?.onTap?.call(hit);
    }
    return event._stopped;
  }

  void exit() {
    if (_disposed || controller.isDisposed) return;
    for (final pointer in _hover.keys.toList()) {
      _hoverStops.remove(pointer);
      final raw = _lastHover.remove(pointer);
      if (raw == null) {
        _hover.remove(pointer);
        continue;
      }
      final (ray, _) = _pick(raw);
      for (final entry in _hover.remove(pointer)!.entries) {
        _deliver(
          _SceneDispatchPhase.leave,
          raw,
          entry.key,
          null,
          const [],
          ray,
        );
      }
    }
  }

  void dispose() {
    _disposed = true;
    _nodes.clear();
    _captures.clear();
    _activePointers.clear();
    _hover.clear();
    _lastHover.clear();
    _hoverStops.clear();
    _tap?.dispose();
    _router?.dispose();
    _interest?.dispose();
    unawaited(_passive?.cancel());
  }
}
