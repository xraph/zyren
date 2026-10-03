import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'scene_canvas.dart';

typedef SceneAssetLoadingBuilder =
    Widget Function(BuildContext context, LoadProgress? progress);
typedef SceneAssetErrorBuilder =
    Widget Function(
      BuildContext context,
      Object error,
      StackTrace stack,
      VoidCallback retry,
    );

/// Loads through the canvas runtime with widget-local cancellation and ownership.
/// Put this widget in SceneCanvas.overlay when your status builders contain
/// visible Flutter controls. Loaded scene nodes still attach to the scene root.
/// Equivalent request values retain the current load. [cache] is caller-owned;
/// otherwise the canvas's shared cache retains completed decoded recipes.
class SceneAsset<T extends Object> extends StatefulWidget {
  final AssetRequest<T> request;
  final Widget Function(BuildContext context, T asset) builder;
  final SceneAssetLoadingBuilder? loadingBuilder;
  final SceneAssetErrorBuilder? errorBuilder;
  final AssetCache? cache;
  const SceneAsset({
    super.key,
    required this.request,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    this.cache,
  });
  @override
  State<SceneAsset<T>> createState() => _SceneAssetState<T>();
}

class _SceneAssetState<T extends Object> extends State<SceneAsset<T>> {
  AssetScope? _scope;
  AssetServices? _services;
  AssetCache? _cache;
  StreamSubscription<LoadProgress>? _progressSubscription;
  int _generation = 0;
  T? _value;
  Object? _error;
  StackTrace? _stack;
  LoadProgress? _progress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = SceneScope.of(context).runtime.assetServices;
    final cache = widget.cache ?? SceneScope.assetCacheOf(context);
    if (!identical(services, _services) || !identical(cache, _cache)) {
      _services = services;
      _cache = cache;
      _start();
    }
  }

  @override
  void didUpdateWidget(SceneAsset<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cache = widget.cache ?? SceneScope.assetCacheOf(context);
    if (widget.request != oldWidget.request || !identical(cache, _cache)) {
      _cache = cache;
      _start();
    }
  }

  void _release() {
    _generation++;
    unawaited(_progressSubscription?.cancel());
    _progressSubscription = null;
    final scope = _scope;
    _scope = null;
    if (scope != null) {
      unawaited(
        scope.close().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'flutter_zyren',
              context: ErrorDescription('while releasing a scene asset'),
            ),
          );
        }),
      );
    }
  }

  void _start() {
    _release();
    final generation = _generation;
    _value = null;
    _error = null;
    _stack = null;
    _progress = null;
    final scope = AssetScope(services: _services!, cache: _cache);
    _scope = scope;
    try {
      final task = scope.load(widget.request);
      _progressSubscription = task.progress.listen((progress) {
        if (!mounted || generation != _generation) return;
        setState(() => _progress = progress);
      });
      task.result.then(
        (value) {
          if (!mounted || generation != _generation) return;
          setState(() => _value = value);
        },
        onError: (Object error, StackTrace stack) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _error = error;
            _stack = stack;
          });
        },
      );
    } catch (error, stack) {
      _error = error;
      _stack = stack;
    }
  }

  void _retry() {
    if (mounted) setState(_start);
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_value case final value?) return widget.builder(context, value);
    if (_error case final error?) {
      return widget.errorBuilder?.call(context, error, _stack!, _retry) ??
          ErrorWidget(error);
    }
    return widget.loadingBuilder?.call(context, _progress) ??
        const SizedBox.shrink();
  }
}

/// Loads a model template and attaches a fresh mutable instance for each mount.
/// Your [builder] receives that instance and builds children beneath its root.
/// Unmounting detaches the root; model instances retain their immutable storage
/// without a disposal API, even after the widget releases its template.
class ModelNode extends StatelessWidget {
  final AssetRequest<ModelAsset> request;
  final int? sceneIndex;
  final bool nativeDeformation;
  final String? name;
  final Vec3? position, scale;
  final Quat? quaternion;
  final bool? visible;
  final SceneRef<ModelInstance>? ref;
  final List<Widget> children;
  final Widget Function(BuildContext context, ModelInstance instance)? builder;
  final void Function(ModelInstance instance, FrameTime time)? onFrame;
  final void Function(PickResult hit)? onTap;
  final void Function(SceneObjectEvent event)? onPointerEnter,
      onPointerLeave,
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel,
      onClick;
  final SceneAssetLoadingBuilder? loadingBuilder;
  final SceneAssetErrorBuilder? errorBuilder;
  final AssetCache? cache;
  const ModelNode({
    super.key,
    required this.request,
    this.sceneIndex,
    this.nativeDeformation = true,
    this.name,
    this.position,
    this.scale,
    this.quaternion,
    this.visible,
    this.ref,
    this.children = const [],
    this.builder,
    this.onFrame,
    this.onTap,
    this.onPointerEnter,
    this.onPointerLeave,
    this.onPointerDown,
    this.onPointerMove,
    this.onPointerUp,
    this.onPointerCancel,
    this.onClick,
    this.loadingBuilder,
    this.errorBuilder,
    this.cache,
  });
  @override
  Widget build(BuildContext context) => SceneAsset<ModelAsset>(
    request: request,
    cache: cache,
    loadingBuilder: loadingBuilder,
    errorBuilder: errorBuilder,
    builder: (context, asset) => _MountedModel(asset: asset, node: this),
  );
}

class _MountedModel extends StatefulWidget {
  final ModelAsset asset;
  final ModelNode node;
  const _MountedModel({required this.asset, required this.node});
  @override
  State<_MountedModel> createState() => _MountedModelState();
}

class _MountedModelState extends State<_MountedModel> {
  ModelInstance? _instance;
  Object? _error;
  StackTrace? _stack;
  @override
  void initState() {
    super.initState();
    _instantiate();
  }

  void _instantiate() {
    try {
      _instance = widget.asset.instantiate(
        sceneIndex: widget.node.sceneIndex,
        name: widget.node.name,
        nativeDeformation: widget.node.nativeDeformation,
      );
      _error = null;
    } catch (error, stack) {
      _instance = null;
      _error = error;
      _stack = stack;
    }
  }

  @override
  void didUpdateWidget(_MountedModel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.asset, oldWidget.asset) ||
        widget.node.sceneIndex != oldWidget.node.sceneIndex ||
        widget.node.nativeDeformation != oldWidget.node.nativeDeformation ||
        widget.node.name != oldWidget.node.name) {
      _instantiate();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final error?) {
      return widget.node.errorBuilder?.call(
            context,
            error,
            _stack!,
            () => setState(_instantiate),
          ) ??
          ErrorWidget(error);
    }
    final node = widget.node, instance = _instance!;
    return ObjectNode<ModelInstance>(
      object: instance,
      ref: node.ref,
      position: node.position,
      scale: node.scale,
      quaternion: node.quaternion,
      visible: node.visible,
      onFrame: node.onFrame,
      onTap: node.onTap,
      onPointerEnter: node.onPointerEnter,
      onPointerLeave: node.onPointerLeave,
      onPointerDown: node.onPointerDown,
      onPointerMove: node.onPointerMove,
      onPointerUp: node.onPointerUp,
      onPointerCancel: node.onPointerCancel,
      onClick: node.onClick,
      children: [
        ...node.children,
        if (node.builder != null) node.builder!(context, instance),
      ],
    );
  }
}
