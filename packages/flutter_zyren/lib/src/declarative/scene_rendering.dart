part of 'scene_canvas.dart';

/// HDR lighting. Configure a ColorPipeline on the canvas. Image replacements
/// use a new attachment so preparation errors reach the normal scene status.
class EnvironmentLightingNode extends StatefulWidget {
  final HdrImageData? image;
  final EnvironmentQuality quality;
  final double intensity;
  final Quat rotation;
  final bool enabled;
  final void Function(SceneIssue, Future<void> Function())? onError;
  final void Function(EnvironmentLighting)? onPlugin;
  const EnvironmentLightingNode({
    super.key,
    this.image,
    this.quality = const EnvironmentQuality(),
    this.intensity = 1,
    this.rotation = Quat.identity,
    this.enabled = true,
    this.onError,
    this.onPlugin,
  });
  @override
  State<EnvironmentLightingNode> createState() =>
      _EnvironmentLightingNodeState();
}

class _EnvironmentLightingNodeState extends State<EnvironmentLightingNode> {
  late EnvironmentLighting _plugin;
  Object? _error;
  void _tryCreate() {
    try {
      _create();
      _error = null;
    } catch (error) {
      _error = error;
    }
  }

  void _create() {
    _plugin = EnvironmentLighting(
      image: widget.image,
      quality: widget.quality,
      intensity: widget.intensity,
      rotation: widget.rotation,
    );
    widget.onPlugin?.call(_plugin);
  }

  @override
  void initState() {
    super.initState();
    _tryCreate();
  }

  @override
  void didUpdateWidget(EnvironmentLightingNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    try {
      _update(oldWidget);
    } catch (error) {
      _error = error;
    }
  }

  void _update(EnvironmentLightingNode oldWidget) {
    if (_error != null ||
        widget.image != oldWidget.image ||
        (
              widget.quality.specularWidth,
              widget.quality.diffuseWidth,
              widget.quality.brdfSize,
              widget.quality.samples,
            ) !=
            (
              _plugin.quality.specularWidth,
              _plugin.quality.diffuseWidth,
              _plugin.quality.brdfSize,
              _plugin.quality.samples,
            )) {
      _tryCreate();
    } else {
      if (widget.intensity != oldWidget.intensity) {
        _plugin.intensity = widget.intensity;
      }
      if (widget.rotation != oldWidget.rotation) {
        _plugin.rotation = widget.rotation;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      throw _error!;
    }
    return ScenePluginNode(
      plugin: _plugin,
      enabled: widget.enabled,
      onError: widget.onError,
    );
  }
}

/// Native graph effects. Configure the canvas ColorPipeline for HDR bloom.
class PostProcessingNode extends StatefulWidget {
  final BloomOptions? bloom;
  final bool antialias, enabled;
  final int maxIntermediateBytes;
  final Set<String> after;
  final void Function(SceneIssue, Future<void> Function())? onError;
  final void Function(PostProcessing)? onPlugin;
  const PostProcessingNode({
    super.key,
    this.bloom,
    this.antialias = false,
    this.enabled = true,
    this.maxIntermediateBytes = 64 * 1024 * 1024,
    this.after = const {},
    this.onError,
    this.onPlugin,
  });
  @override
  State<PostProcessingNode> createState() => _PostProcessingNodeState();
}

class _PostProcessingNodeState extends State<PostProcessingNode> {
  late PostProcessing _plugin;
  Object? _error;
  void _tryCreate() {
    try {
      _create();
      _error = null;
    } catch (error) {
      _error = error;
    }
  }

  void _create() {
    _plugin = PostProcessing(
      bloom: widget.bloom,
      antialias: widget.antialias,
      maxIntermediateBytes: widget.maxIntermediateBytes,
      after: widget.after,
    );
    widget.onPlugin?.call(_plugin);
  }

  @override
  void initState() {
    super.initState();
    _tryCreate();
  }

  @override
  void didUpdateWidget(PostProcessingNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    try {
      _update(oldWidget);
    } catch (error) {
      _error = error;
    }
  }

  void _update(PostProcessingNode oldWidget) {
    if (_error != null ||
        widget.maxIntermediateBytes != oldWidget.maxIntermediateBytes ||
        widget.after.length != _plugin.after.length ||
        !widget.after.containsAll(_plugin.after)) {
      _tryCreate();
    } else {
      if (widget.bloom != oldWidget.bloom) {
        _plugin.bloom = widget.bloom;
      }
      if (widget.antialias != oldWidget.antialias) {
        _plugin.antialias = widget.antialias;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      throw _error!;
    }
    return ScenePluginNode(
      plugin: _plugin,
      enabled: widget.enabled,
      onError: widget.onError,
    );
  }
}
