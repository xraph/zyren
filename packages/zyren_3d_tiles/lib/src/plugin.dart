part of '../zyren_3d_tiles.dart';

class Tiles3DPlugin extends ScenePlugin {
  Tileset3D _tileset;
  final AssetServices services;
  final Tiles3DBudget? budget;
  final double maximumScreenError;
  final Duration fadeDuration;
  final GltfOptions options;
  final void Function(Tiles3DStats)? onChanged;
  Tiles3DStreamer? _streamer;
  Group? _group;
  PluginContext? _context;
  Tiles3DPlugin({
    required Tileset3D tileset,
    required this.services,
    this.budget,
    this.maximumScreenError = 8,
    this.fadeDuration = Duration.zero,
    this.options = const GltfOptions(),
    this.onChanged,
  }) : _tileset = tileset;
  @override
  String get id => 'tiles3d';
  Tiles3DStats? get stats => _streamer?.stats;
  bool get isTransitioning => _streamer?.isTransitioning ?? false;
  List<String> get attributions => _streamer?.attributions ?? const [];
  List<TileFailure3D> get failures => _streamer?.failures ?? const [];
  Set<String> get visibleTileIds =>
      Set.unmodifiable(_streamer?.visible.keys ?? const <String>[]);
  @override
  void attach(PluginContext context) {
    _context = context;
    _streamer = Tiles3DStreamer(
      tileset: _tileset,
      services: services,
      budget: budget,
      options: options,
      maximumScreenError: maximumScreenError,
      fadeDuration: fadeDuration,
      onChanged: () {
        _sync();
        context.invalidate();
        final stats = this.stats;
        if (stats != null) onChanged?.call(stats);
      },
    );
    _group = Group(name: '3D Tiles');
    context.scene.add(_group!);
  }

  void replaceTileset(Tileset3D tileset) {
    _tileset = tileset;
    _streamer?.replaceTileset(tileset);
    _sync();
    _context?.invalidate();
  }

  void retryFailed() {
    _streamer?.retryFailed();
    _context?.invalidate();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    final input = context.input;
    _streamer!.update(
      context.camera,
      input is ViewportInputSource
          ? input.viewport
          : ViewportMetrics(frame.width.toDouble(), frame.height.toDouble()),
      elapsed: frame.elapsed,
    );
    _sync();
    if (isTransitioning) context.invalidate();
  }

  void _sync() {
    final group = _group, streamer = _streamer;
    if (group == null || streamer == null) return;
    final visible = streamer.visible.values.toSet();
    for (final child in group.children) {
      if (!visible.contains(child)) group.remove(child);
    }
    for (final child in visible) {
      if (child.parent != group) group.add(child);
    }
  }

  @override
  Future<void> detach(PluginContext context) async {
    final streamer = _streamer;
    _streamer = null;
    final group = _group;
    _group = null;
    _context = null;
    if (group != null) context.scene.remove(group);
    await streamer?.dispose();
  }
}
