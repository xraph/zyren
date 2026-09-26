import '../scene/scene.dart';
import 'frame_output.dart';

class FrameTime {
  final Duration elapsed, delta, rawDelta;
  final int index;
  const FrameTime({
    this.elapsed = Duration.zero,
    this.delta = Duration.zero,
    this.rawDelta = Duration.zero,
    this.index = 0,
  });
  double get elapsedSeconds =>
      elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  double get deltaSeconds =>
      delta.inMicroseconds / Duration.microsecondsPerSecond;
}

class CameraSnapshot {
  final List<double> origin, viewProjection;
  CameraSnapshot._(Iterable<double> origin, Iterable<double> viewProjection)
    : origin = List.unmodifiable(origin),
      viewProjection = List.unmodifiable(viewProjection);
}

/// Immutable ABI v1 data until binary resources replace the legacy packet.
class SceneSnapshot {
  final Map<String, Object> _packet;
  final int drawCalls, triangles;
  SceneSnapshot._(Map<String, Object> packet)
    : _packet = _freeze(packet) as Map<String, Object>,
      drawCalls = (packet['meshes'] as List).length,
      triangles = _triangleCount(packet);

  static int _triangleCount(Map<String, Object> packet) {
    final counts = <int, int>{
      for (final geometry in packet['geometries'] as List)
        (geometry as Map)['id'] as int:
            (geometry['indices'] as List).length ~/ 3,
    };
    return (packet['meshes'] as List).fold<int>(
      0,
      (count, mesh) => count + counts[(mesh as Map)['geometry']]!,
    );
  }
}

class FrameSubmission {
  final SceneSnapshot scene;
  final CameraSnapshot camera;
  final OutputTarget target;
  final PhysicalSize size;
  final FrameTime time;
  final Duration cpuBuildTime;
  FrameSubmission._(
    this.scene,
    this.camera,
    this.target,
    this.size,
    this.time,
    this.cpuBuildTime,
  );

  /// Captures once so changes made during an asynchronous render affect only
  /// later submissions. This does not allocate a GPU or require Flutter.
  factory FrameSubmission.capture({
    required Scene scene,
    required Camera camera,
    required PhysicalSize size,
    OutputTarget target = const ReadbackTarget(),
    FrameTime time = const FrameTime(),
  }) {
    final clock = Stopwatch()..start();
    final packet = scene.snapshot(camera, size.width / size.height);
    final cameraSnapshot = CameraSnapshot._(
      camera.position.storage,
      (packet['view_projection'] as List<double>),
    );
    final sceneSnapshot = SceneSnapshot._(packet);
    return FrameSubmission._(
      sceneSnapshot,
      cameraSnapshot,
      target,
      size,
      time,
      clock.elapsed,
    );
  }

  /// Temporary ABI v1 encoder. Returned collections cannot modify the snapshot.
  Map<String, Object> toNativePacket({Set<int> uploaded = const {}}) =>
      Map.unmodifiable({
        ...scene._packet,
        'geometries': List.unmodifiable([
          for (final geometry in scene._packet['geometries'] as List)
            if (!uploaded.contains((geometry as Map)['id'])) geometry,
        ]),
      });
}

Object _freeze(Object value) => switch (value) {
  Map<String, Object> map => Map<String, Object>.unmodifiable({
    for (final entry in map.entries) entry.key: _freeze(entry.value),
  }),
  List list => List<Object>.unmodifiable(
    list.map((item) => _freeze(item as Object)),
  ),
  _ => value,
};
