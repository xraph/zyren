part of '../zyren_tools.dart';

const sceneOutlines = ServiceKey<SceneOutlinePlugin>('zyren.outlines');

/// Follows tools selection while preserving externally owned outline edits.
class SceneOutlinePlugin extends ScenePlugin {
  @override
  String get id => 'zyren.outlines';
  @override
  Set<String> get dependencies => {'zyren.tools'};
  @override
  Set<RenderFeature> get requiredFeatures => {RenderFeature.selectionOutlines};
  final Color3 color;
  final int width;
  final double opacity;
  PluginContext? _context;
  SceneOutline? _previous, _owned;
  Object3D? _selected;
  SceneOutlinePlugin({Color3? color, this.width = 2, this.opacity = 1})
    : color = color ?? Color3.hex(0xf2bd65) {
    SceneOutline(
      objects: const [],
      color: this.color,
      width: width,
      opacity: opacity,
    );
  }
  bool get isActive =>
      _owned != null && identical(_context?.scene.outline, _owned);

  @override
  void attach(PluginContext context) {
    _context = context;
    context.provide(sceneOutlines, this);
    final tools = context.service(sceneTools);
    context.scope.listen(tools.changes, (_) => _sync(tools.selected));
    _sync(tools.selected);
  }

  void _sync(Object3D? selected) {
    if (_context == null || identical(_selected, selected)) return;
    final scene = _context!.scene;
    if (isActive) scene.outline = _previous;
    _previous = _owned = null;
    _selected = selected;
    if (selected == null) return;
    _previous = scene.outline;
    _owned = SceneOutline(
      objects: [selected],
      color: color,
      width: width,
      opacity: opacity,
    );
    scene.outline = _owned;
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _sync(context.service(sceneTools).selected);
  }

  @override
  void detach(PluginContext context) {
    if (isActive) context.scene.outline = _previous;
    _context = null;
    _previous = _owned = null;
    _selected = null;
  }
}
