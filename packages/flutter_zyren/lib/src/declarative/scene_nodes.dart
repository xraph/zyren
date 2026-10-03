part of 'scene_canvas.dart';

/// A stable handle for imperative edits. Keep it in State, outside build.
/// [current] is null while the node is unmounted. One ref belongs to one node.
class SceneRef<T extends Object3D> {
  T? _current;
  Object? _owner;
  T? get current => _current;
  T get require => _current ?? (throw StateError('SceneRef is not mounted.'));
  void _bind(Object owner, T object) {
    if (_owner != null && !identical(_owner, owner)) {
      throw FlutterError('A SceneRef cannot be attached to two scene nodes.');
    }
    _owner = owner;
    _current = object;
  }

  void _clear(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _current = null;
  }
}

/// Base for custom declarative engine objects. Implement creation and property
/// updates through Zyren's public API. Null transforms leave imperative edits
/// alone; changed, non-null transforms override them on the next rebuild.
abstract class SceneNode<T extends Object3D> extends StatefulWidget {
  final String? name;
  final Vec3? position, scale;
  final Quat? quaternion;
  final bool? visible;
  final SceneRef<T>? ref;
  final List<Widget> children;
  final void Function(T object, FrameTime time)? onFrame;
  final void Function(PickResult hit)? onTap;
  final void Function(SceneObjectEvent event)? onPointerEnter,
      onPointerLeave,
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel,
      onClick;
  const SceneNode({
    super.key,
    this.name,
    this.position,
    this.scale,
    this.quaternion,
    this.visible,
    this.ref,
    this.children = const [],
    this.onFrame,
    this.onTap,
    this.onPointerEnter,
    this.onPointerLeave,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerCancel,
    this.onClick,
  });
  T createObject();
  void updateObject(T object, covariant SceneNode<T>? previous) {}
  bool shouldRecreate(covariant SceneNode<T> previous) => name != previous.name;
  @override
  State<SceneNode<T>> createState() => _SceneNodeState<T>();
}

final _nodeOwners = Expando<Object>('declarative scene object owner');

class _SceneNodeState<T extends Object3D> extends State<SceneNode<T>> {
  late T object;
  _SceneCanvasState? _host;
  Object3D? _parent;
  Registration? _frame;
  bool _attached = false;
  Object? _creationError;

  @override
  void initState() {
    super.initState();
    try {
      object = widget.createObject();
      _validateObject(object);
      _apply(null);
    } catch (error) {
      _creationError = error;
    }
  }

  void _validateObject(T next) {
    if (_nodeOwners[next] != null || next.parent != null) {
      throw FlutterError(
        'Object ${next.name ?? next.id} already belongs to a scene. '
        'Mount each ObjectNode once and remove it from its old parent first.',
      );
    }
  }

  void _apply(SceneNode<T>? previous) {
    if (widget.position != null && widget.position != previous?.position) {
      object.position = widget.position!;
    }
    if (widget.scale != null && widget.scale != previous?.scale) {
      object.scale = widget.scale!;
    }
    if (widget.quaternion != null &&
        widget.quaternion != previous?.quaternion) {
      object.quaternion = widget.quaternion!;
    }
    if (widget.visible != null && widget.visible != previous?.visible) {
      object.visible = widget.visible!;
    }
    widget.updateObject(object, previous);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_creationError != null) return;
    try {
      _bindParent();
    } catch (error) {
      // Report through build so Flutter can mount an ErrorWidget and clean up.
      _creationError = error;
    }
  }

  void _bindParent() {
    final host = _SceneHost.of(context);
    final parent = context
        .dependOnInheritedWidgetOfExactType<_SceneParent>()!
        .object;
    if (!_attached || host != _host || parent != _parent) {
      _detach();
      _host = host;
      _parent = parent;
      if (_nodeOwners[object] != null && _nodeOwners[object] != this) {
        throw FlutterError('An ObjectNode cannot be mounted twice.');
      }
      widget.ref?._bind(this, object);
      try {
        parent.add(object);
      } catch (_) {
        widget.ref?._clear(this);
        rethrow;
      }
      _nodeOwners[object] = this;
      _attached = true;
    }
    _syncCallbacks();
  }

  void _syncCallbacks() {
    if (!_attached) return;
    _host!.events.set(object, widget);
    if (widget.onFrame == null) {
      _frame?.dispose();
      _frame = null;
    } else {
      _frame ??= _host!.controller.onUpdate(
        (time) => widget.onFrame?.call(object, time),
      );
    }
  }

  @override
  void didUpdateWidget(covariant SceneNode<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    try {
      if (_creationError != null) {
        oldWidget.ref?._clear(this);
        object = widget.createObject();
        _validateObject(object);
        _apply(null);
        _bindParent();
        _creationError = null;
      } else {
        _updateObject(oldWidget);
      }
    } catch (error) {
      oldWidget.ref?._clear(this);
      _detach();
      _creationError = error;
    }
  }

  void _updateObject(SceneNode<T> oldWidget) {
    if (widget.shouldRecreate(oldWidget)) {
      final next = widget.createObject();
      _validateObject(next);
      // Preserve animation state across immutable geometry/name replacement.
      if (widget is! ObjectNode<T>) {
        next.position = object.position;
        next.scale = object.scale;
        next.quaternion = object.quaternion;
        next.visible = object.visible;
      }
      _host?.events.remove(object);
      _parent?.remove(object);
      _nodeOwners[object] = null;
      object = next;
      if (_attached) {
        _parent!.add(object);
        _nodeOwners[object] = this;
      }
      _apply(null);
    } else {
      _apply(oldWidget);
    }
    if (oldWidget.ref != widget.ref) oldWidget.ref?._clear(this);
    if (_attached) widget.ref?._bind(this, object);
    _syncCallbacks();
  }

  void _detach() {
    _frame?.dispose();
    _frame = null;
    if (_attached) {
      _host?.events.remove(object);
      _parent?.remove(object);
      _nodeOwners[object] = null;
      widget.ref?._clear(this);
      _attached = false;
    }
  }

  @override
  void deactivate() {
    _detach();
    super.deactivate();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_creationError != null) throw _creationError!;
    return _SceneParent(
      object: object,
      child: _SceneChildren(children: widget.children),
    );
  }
}

class GroupNode extends SceneNode<Group> {
  const GroupNode({
    super.key,
    super.name,
    super.position,
    super.scale,
    super.quaternion,
    super.visible,
    super.ref,
    super.children,
    super.onFrame,
    super.onTap,
    super.onPointerEnter,
    super.onPointerLeave,
    super.onPointerDown,
    super.onPointerMove,
    super.onPointerUp,
    super.onPointerCancel,
    super.onClick,
  });
  @override
  Group createObject() => Group(name: name);
}

class MeshNode extends SceneNode<Mesh> {
  final SceneGeometry geometry;
  final SceneMaterial material;
  final bool castShadow, receiveShadow;
  final int renderOrder;
  const MeshNode({
    super.key,
    super.name,
    required this.geometry,
    this.material = const SceneMaterial.unlit(),
    this.castShadow = false,
    this.receiveShadow = false,
    this.renderOrder = 0,
    super.position,
    super.scale,
    super.quaternion,
    super.visible,
    super.ref,
    super.children,
    super.onFrame,
    super.onTap,
    super.onPointerEnter,
    super.onPointerLeave,
    super.onPointerDown,
    super.onPointerMove,
    super.onPointerUp,
    super.onPointerCancel,
    super.onClick,
  });
  @override
  Mesh createObject() => Mesh(geometry.create(), material.create(), name: name);
  @override
  bool shouldRecreate(MeshNode previous) =>
      super.shouldRecreate(previous) || geometry != previous.geometry;
  @override
  void updateObject(Mesh object, MeshNode? previous) {
    if (previous != null && material != previous.material) {
      object.material = material.create();
    }
    object.castShadow = castShadow;
    object.receiveShadow = receiveShadow;
    object.renderOrder = renderOrder;
  }
}

/// Borrows an existing object, including loaded model roots and plugin objects.
/// Unmounting detaches it; the original owner still manages external resources.
class ObjectNode<T extends Object3D> extends SceneNode<T> {
  final T object;
  const ObjectNode({
    super.key,
    required this.object,
    super.position,
    super.scale,
    super.quaternion,
    super.visible,
    super.ref,
    super.children,
    super.onFrame,
    super.onTap,
    super.onPointerEnter,
    super.onPointerLeave,
    super.onPointerDown,
    super.onPointerMove,
    super.onPointerUp,
    super.onPointerCancel,
    super.onClick,
  });
  @override
  T createObject() => object;
  @override
  bool shouldRecreate(ObjectNode<T> previous) =>
      !identical(object, previous.object);
}

class DirectionalLightNode extends SceneNode<DirectionalLight> {
  final Color3 color;
  final double intensity;
  final Vec3 direction;
  const DirectionalLightNode({
    super.key,
    super.name,
    this.color = const Color3(1, 1, 1),
    this.intensity = 1,
    this.direction = const Vec3(0, -1, -1),
    super.position,
    super.quaternion,
    super.visible,
    super.ref,
    super.onFrame,
  });
  @override
  DirectionalLight createObject() => DirectionalLight(
    name: name,
    color: color,
    intensity: intensity,
    direction: direction,
  );
  @override
  void updateObject(DirectionalLight object, DirectionalLightNode? previous) {
    if (previous == null || color != previous.color) object.color = color;
    if (previous == null || intensity != previous.intensity) {
      object.intensity = intensity;
    }
    if (previous == null || direction != previous.direction) {
      object.direction = direction;
    }
  }
}
