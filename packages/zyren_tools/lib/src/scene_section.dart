part of '../zyren_tools.dart';

const sceneSections = ServiceKey<SceneSectionPlugin>('zyren.sections');

/// A reversible section session. External edits take ownership immediately.
class SceneSectionPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.sections';
  final _changes = StreamController<void>.broadcast();
  PluginContext? _context;
  List<ClippingPlane>? _previous, _owned;
  Stream<void> get changes => _changes.stream;
  bool get isActive =>
      _owned != null && identical(_context?.scene.clippingPlanes, _owned);
  List<ClippingPlane> get planes => isActive ? _owned! : const [];

  @override
  void attach(PluginContext context) {
    _context = context;
    context.provide(sceneSections, this);
    context.scope.listen(context.scene.changes, (_) => _releaseExternal());
  }

  void _releaseExternal() {
    if (_owned == null || isActive) return;
    _previous = _owned = null;
    _changes.add(null);
  }

  /// Replaces this session's planes. An empty list restores the earlier scene.
  void setPlanes(List<ClippingPlane> value) {
    final scene =
        _context?.scene ??
        (throw StateError('Attach sections before using them.'));
    if (value.isEmpty) {
      clear();
      return;
    }
    if (value.length > 6) {
      throw ArgumentError('At most six section planes are supported.');
    }
    _releaseExternal();
    _previous ??= scene.clippingPlanes;
    scene.clippingPlanes = value;
    _owned = scene.clippingPlanes;
    _changes.add(null);
  }

  void clear() {
    final context =
        _context ?? (throw StateError('Attach sections before using them.'));
    if (isActive) context.scene.clippingPlanes = _previous!;
    _previous = _owned = null;
    _changes.add(null);
  }

  @override
  void detach(PluginContext context) {
    clear();
    _context = null;
  }
}
