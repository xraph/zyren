part of 'scene_canvas.dart';

/// Registers an existing family plugin with this canvas. Keep [plugin] stable
/// across builds. The engine owns its attachment scope, not the instance itself.
/// Use [ScenePluginNode.create] to create one instance for this widget's lifetime.
class ScenePluginNode extends StatefulWidget {
  final ScenePlugin? plugin;
  final ScenePlugin Function()? create;
  final Object? factoryKey;
  final bool enabled;
  final void Function(SceneIssue issue, Future<void> Function() retry)? onError;
  final Widget child;
  const ScenePluginNode({
    super.key,
    required ScenePlugin this.plugin,
    this.enabled = true,
    this.onError,
    this.child = const SizedBox.shrink(),
  }) : create = null,
       factoryKey = null;

  /// The factory runs once, including while disabled. Change [factoryKey] to
  /// replace the plugin. Rebuilding with a new closure alone retains it.
  const ScenePluginNode.create({
    super.key,
    required ScenePlugin Function() this.create,
    this.factoryKey,
    this.enabled = true,
    this.onError,
    this.child = const SizedBox.shrink(),
  }) : plugin = null;
  @override
  State<ScenePluginNode> createState() => _ScenePluginNodeState();
}

class _ScenePluginNodeState extends State<ScenePluginNode> {
  final _token = Object();
  _SceneCanvasState? _host;
  late ScenePlugin _plugin;
  SceneIssue? _lastIssue;
  @override
  void initState() {
    super.initState();
    _plugin = widget.plugin ?? widget.create!();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = _SceneHost.of(context);
    if (!identical(host, _host)) {
      _host?.controller.state.removeListener(_onState);
      _host?._registerPlugin(_token, null);
      _host = host;
      _lastIssue = null;
      host.controller.state.addListener(_onState);
    }
    _sync();
  }

  void _onState() {
    if (!mounted || _host == null) return;
    final issue = _host!.controller.pluginIssue;
    if (identical(issue, _lastIssue)) return;
    _lastIssue = issue;
    if (issue != null) {
      widget.onError?.call(issue, _host!.controller.retryPlugins);
    }
  }

  void _sync() =>
      _host?._registerPlugin(_token, widget.enabled ? _plugin : null);
  @override
  void didUpdateWidget(ScenePluginNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.plugin != null) {
      _plugin = widget.plugin!;
    } else if (oldWidget.create == null ||
        widget.factoryKey != oldWidget.factoryKey) {
      _plugin = widget.create!();
    }
    _sync();
  }

  @override
  void deactivate() {
    _host?.controller.state.removeListener(_onState);
    _host?._registerPlugin(_token, null);
    _host = null;
    super.deactivate();
  }

  @override
  void dispose() {
    _host?.controller.state.removeListener(_onState);
    _host?._registerPlugin(_token, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Live orbit configuration. Use this node or [SceneCanvas.orbitControls] once
/// per canvas. Changes replace controls while retaining the camera and session.
class OrbitControlsNode extends StatefulWidget {
  final bool enabled, keyboard;
  final OrbitBehavior behavior;

  /// Applied to the existing controls when the callback changes. Values you do
  /// not assign retain their previous setting. Keyboard and behavior changes
  /// create fresh controls; ordinary parent rebuilds retain the same instance.
  final void Function(OrbitControls)? configure;
  final Widget child;
  const OrbitControlsNode({
    super.key,
    this.enabled = true,
    this.keyboard = false,
    this.behavior = OrbitBehavior.stdlib236,
    this.configure,
    this.child = const SizedBox.shrink(),
  });
  @override
  State<OrbitControlsNode> createState() => _OrbitControlsNodeState();
}

class _OrbitControlsNodeState extends State<OrbitControlsNode> {
  late OrbitControlsPlugin _plugin = _create();
  OrbitControlsPlugin _create() => OrbitControlsPlugin(
    keyboard: widget.keyboard,
    behavior: widget.behavior,
    configure: (controls) => widget.configure?.call(controls),
  );
  @override
  void didUpdateWidget(OrbitControlsNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.keyboard != oldWidget.keyboard ||
        widget.behavior != oldWidget.behavior) {
      _plugin = _create();
    } else if (widget.configure != oldWidget.configure &&
        _plugin.controls != null) {
      widget.configure?.call(_plugin.controls!);
      _plugin.controls!.update();
      SceneScope.of(context).invalidate();
    }
  }

  @override
  Widget build(BuildContext context) => ScenePluginNode(
    enabled: widget.enabled,
    plugin: _plugin,
    child: widget.child,
  );
}
