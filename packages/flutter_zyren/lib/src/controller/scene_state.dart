part of 'scene_controller.dart';

@immutable
class SceneViewport {
  final Size logicalSize;
  final double devicePixelRatio;
  const SceneViewport(this.logicalSize, this.devicePixelRatio);
  double get width => logicalSize.width;
  double get height => logicalSize.height;
  @override
  bool operator ==(Object other) =>
      other is SceneViewport &&
      logicalSize == other.logicalSize &&
      devicePixelRatio == other.devicePixelRatio;
  @override
  int get hashCode => Object.hash(logicalSize, devicePixelRatio);
}

/// Transform values are captured; [camera] and [selection] are identity handles.
/// Selecting camera identity does not subscribe to its mutable transform.
/// Select [cameraPosition], [cameraTarget] or [cameraRevision] for those changes.
@immutable
class SceneState {
  final Camera camera;
  final Vec3 cameraPosition, cameraTarget, cameraUp;
  final int cameraRevision;
  final SceneViewport viewport;
  final Object3D? selection;
  final SceneStatus status;
  final RendererInfo? renderer;
  final FrameStats? frameStats;
  final List<String> pluginIds;
  final SceneIssue? pluginIssue;
  SceneState({
    required Camera camera,
    required Vec3 cameraPosition,
    required Vec3 cameraTarget,
    required Vec3 cameraUp,
    required int cameraRevision,
    required SceneViewport viewport,
    required Object3D? selection,
    required SceneStatus status,
    required RendererInfo? renderer,
    required FrameStats? frameStats,
    required Iterable<String> pluginIds,
    required SceneIssue? pluginIssue,
  }) : this._(
         camera: camera,
         cameraPosition: cameraPosition,
         cameraTarget: cameraTarget,
         cameraUp: cameraUp,
         cameraRevision: cameraRevision,
         viewport: viewport,
         selection: selection,
         status: status,
         renderer: renderer,
         frameStats: frameStats,
         pluginIssue: pluginIssue,
         pluginIds: List.unmodifiable(pluginIds),
       );
  SceneState._({
    required this.camera,
    required this.cameraPosition,
    required this.cameraTarget,
    required this.cameraUp,
    required this.cameraRevision,
    required this.viewport,
    required this.selection,
    required this.status,
    required this.renderer,
    required this.frameStats,
    required this.pluginIssue,
    required this.pluginIds,
  });

  bool _sameValues(SceneState other) =>
      identical(camera, other.camera) &&
      cameraPosition == other.cameraPosition &&
      cameraTarget == other.cameraTarget &&
      cameraUp == other.cameraUp &&
      cameraRevision == other.cameraRevision &&
      viewport == other.viewport &&
      identical(selection, other.selection) &&
      identical(status, other.status) &&
      identical(renderer, other.renderer) &&
      identical(frameStats, other.frameStats) &&
      listEquals(pluginIds, other.pluginIds) &&
      identical(pluginIssue, other.pluginIssue);
}

class _SceneStateListenable extends ChangeNotifier
    implements ValueListenable<SceneState> {
  final SceneState Function() capture;
  SceneState? _current;
  bool _scheduled = false, _closed = false;
  _SceneStateListenable(this.capture);
  // Reads include synchronous layout and scene mutations before notification.
  @override
  SceneState get value {
    final next = capture();
    if (_current == null || !_current!._sameValues(next)) _current = next;
    return _current!;
  }

  void publish() {
    if (_scheduled || _closed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_closed) notifyListeners();
    });
  }

  void close() {
    _closed = true;
    dispose();
  }
}
