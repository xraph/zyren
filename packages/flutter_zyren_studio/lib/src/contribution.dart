part of '../flutter_zyren_studio.dart';

typedef StudioEditorWidgetBuilder =
    Widget Function(BuildContext, StudioEditorContext);

final class StudioEditorContribution {
  final String id;
  final int version;
  final Set<String> dependencies;
  final void Function(StudioEditorContext) attach;
  final StudioAgentExtension? runtimeExtension;
  StudioEditorContribution({
    required String id,
    required this.version,
    Set<String> dependencies = const {},
    required this.attach,
    this.runtimeExtension,
  }) : id = _editorId(id),
       dependencies = Set.unmodifiable(dependencies.map(_editorId)) {
    if (version < 1) throw ArgumentError.value(version, 'version');
  }
}

enum StudioEditorDock { left, leftLower, right, rightLower, bottom }

final class StudioEditorPanel {
  final String id, title;
  final IconData icon;
  final StudioEditorWidgetBuilder builder;
  final StudioEditorDock defaultDock;
  final bool initiallyOpen;
  final int order;
  StudioEditorPanel({
    required String id,
    required this.title,
    required this.icon,
    required this.builder,
    this.defaultDock = StudioEditorDock.right,
    this.initiallyOpen = false,
    this.order = 0,
  }) : id = _editorId(id);
}

final class StudioEditorInspector {
  final String id, title;
  final bool Function(StudioEditorContext) applies;
  final StudioEditorWidgetBuilder builder;
  StudioEditorInspector({
    required String id,
    required this.title,
    required this.applies,
    required this.builder,
  }) : id = _editorId(id);
}

final class StudioEditorAssetKind {
  final String id, label;
  final Set<String> extensions;
  final Future<void> Function(StudioEditorContext, Uri) importAsset;
  StudioEditorAssetKind({
    required String id,
    required this.label,
    required Set<String> extensions,
    required this.importAsset,
  }) : id = _editorId(id),
       extensions = Set.unmodifiable(
         extensions.map((e) => _editorId(e.toLowerCase())),
       ) {
    if (extensions.isEmpty ||
        extensions.length > 32 ||
        extensions.any((e) => e.contains('.') || e.contains('/'))) {
      throw ArgumentError(
        'Use up to 32 file extensions without dots or slashes.',
      );
    }
  }
}

final class StudioEditorCreationTool {
  final String id, label;
  final IconData icon;
  final bool Function(StudioEditorContext) enabled;
  final FutureOr<void> Function(StudioEditorContext) create;
  StudioEditorCreationTool({
    required String id,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.create,
  }) : id = _editorId(id);
}

final class StudioEditorOverlay {
  final String id;
  final StudioEditorWidgetBuilder builder;
  final bool interactive;
  StudioEditorOverlay({
    required String id,
    required this.builder,
    this.interactive = false,
  }) : id = _editorId(id);
}

final class StudioEditorProblem {
  final String id, message;
  final bool blocking;
  const StudioEditorProblem(this.id, this.message, {this.blocking = false});
}

final class StudioEditorValidator {
  final String id;
  final FutureOr<List<StudioEditorProblem>> Function(
    StudioEditorContext,
    StudioDocument,
  )
  validate;
  StudioEditorValidator({required String id, required this.validate})
    : id = _editorId(id);
}

abstract interface class StudioEditorPlaySession {
  String get id;
  bool get isPaused;
  FutureOr<void> pause();
  FutureOr<void> resume();
  FutureOr<void> step();
  FutureOr<void> close();
}

final class StudioEditorPlayFactory {
  final String id, label;
  final bool Function(StudioEditorContext, StudioDocument) supports;
  final Future<StudioEditorPlaySession> Function(
    StudioEditorContext,
    StudioDocument,
  )
  create;
  StudioEditorPlayFactory({
    required String id,
    required this.label,
    required this.supports,
    required this.create,
  }) : id = _editorId(id);
}

/// Converts local scene positions to a plugin's display coordinates and back.
/// The plugin owns CRS, origin, parent transforms and range validation.
final class StudioEditorPlacement {
  final String id, title;
  final List<String> labels, units;
  final int precision, priority;
  final bool Function(StudioEditorContext) applies;
  final Vec3 Function(StudioEditorContext, Vec3) toDisplay, toLocal;
  StudioEditorPlacement({
    required String id,
    required this.title,
    required List<String> labels,
    List<String> units = const ['', '', ''],
    this.precision = 3,
    this.priority = 0,
    required this.applies,
    required this.toDisplay,
    required this.toLocal,
  }) : id = _editorId(id),
       labels = List.unmodifiable(labels),
       units = List.unmodifiable(units) {
    if (labels.length != 3 ||
        labels.any((s) => s.trim().isEmpty) ||
        units.length != 3 ||
        precision < 0 ||
        precision > 12) {
      throw ArgumentError(
        'Placement needs three axes and 0 to 12 decimal places.',
      );
    }
  }
}

final class StudioEditorPlacementBinding {
  final StudioEditorPlacement definition;
  final StudioEditorContext _context;
  StudioEditorPlacementBinding._(this.definition, this._context);
  Vec3 _convert(Vec3 value, Vec3 Function(StudioEditorContext, Vec3) convert) {
    _context._check();
    if (!_context._owner.runtimeReady) {
      throw StateError('Placement plugin is unavailable.');
    }
    if (!value.isFinite) throw ArgumentError('Coordinates must be finite.');
    final result = convert(_context, value);
    if (!result.isFinite) {
      throw ArgumentError('Converted coordinates must be finite.');
    }
    return result;
  }

  Vec3 toDisplay(Vec3 local) => _convert(local, definition.toDisplay);
  Vec3 toLocal(Vec3 display) => _convert(display, definition.toLocal);
}
