import 'package:zyren/zyren.dart';

/// A validated perspective camera pose with an application-owned stable ID.
final class ConfigurationCameraPreset {
  final String id;
  final Vec3 position, target, up;
  final double fieldOfView, near, far;
  ConfigurationCameraPreset({
    required this.id,
    required this.position,
    required this.target,
    this.up = const Vec3(0, 1, 0),
    this.fieldOfView = 0.872664625997,
    this.near = .1,
    this.far = 1000,
  }) {
    if (id.trim().isEmpty) throw ArgumentError('Preset ID is blank.');
    createCamera();
  }
  PerspectiveCamera createCamera() => PerspectiveCamera(
    position: position,
    target: target,
    up: up,
    fieldOfView: fieldOfView,
    near: near,
    far: far,
  );

  void apply(PerspectiveCamera camera) {
    camera.position = position;
    camera.target = target;
    camera.up = up;
    camera.fieldOfView = fieldOfView;
    // Relax far first so moving the whole clip interval remains valid.
    if (far > camera.far) camera.far = far;
    camera.near = near;
    camera.far = far;
  }
}

final class ConfigurationHotspot {
  final String id, targetId, label;
  final Vec3 localPosition;
  final String? presetId;
  ConfigurationHotspot({
    required this.id,
    required this.targetId,
    required this.label,
    this.localPosition = Vec3.zero,
    this.presetId,
  }) {
    if (id.trim().isEmpty ||
        targetId.trim().isEmpty ||
        !localPosition.isFinite) {
      throw ArgumentError('Invalid hotspot identity or position.');
    }
  }
}

/// Projects anchors with the host's active camera. Clipping is geometric evidence;
/// objects or Flutter overlays may still occlude an anchor inside the frustum.
final class ConfigurationViewpoints {
  final Map<String, ConfigurationCameraPreset> presets;
  final Map<String, ConfigurationHotspot> hotspots;
  final Map<String, Object3D> targets;
  ConfigurationViewpoints({
    required Iterable<ConfigurationCameraPreset> presets,
    required Iterable<ConfigurationHotspot> hotspots,
    required Map<String, Object3D> targets,
  }) : presets = _unique(presets, (v) => v.id),
       hotspots = _unique(hotspots, (v) => v.id),
       targets = Map.unmodifiable(targets) {
    for (final point in this.hotspots.values) {
      if (!targets.containsKey(point.targetId) ||
          (point.presetId != null &&
              !this.presets.containsKey(point.presetId))) {
        throw ArgumentError('Unknown hotspot target or camera preset.');
      }
    }
  }
  List<Map<String, Object?>> project(Camera camera, ViewportMetrics viewport) {
    if (!viewport.isUsable) throw ArgumentError('Viewport is not usable.');
    return [
      for (final point in hotspots.values) _project(point, camera, viewport),
    ];
  }

  Map<String, Object?> _project(
    ConfigurationHotspot point,
    Camera camera,
    ViewportMetrics viewport,
  ) {
    final node = targets[point.targetId]!;
    final m = node.worldMatrix.storage, p = point.localPosition;
    final world = Vec3(
      m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
      m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
      m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
    );
    final front =
        (world - camera.position).dot(camera.target - camera.position) > 0;
    // The camera plane has no finite perspective projection.
    final ndc = front ? camera.projectPoint(world, viewport.aspect) : null;
    var visible = true;
    for (
      Object3D? ancestor = node;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      visible = visible && ancestor.visible;
    }
    final inside =
        visible &&
        ndc != null &&
        ndc.isFinite &&
        ndc.x.abs() <= 1 &&
        ndc.y.abs() <= 1 &&
        ndc.z >= 0 &&
        ndc.z <= 1;
    return {
      'id': point.id,
      'targetId': point.targetId,
      'label': point.label,
      'presetId': point.presetId,
      'insideFrustum': inside,
      'x': ndc == null ? null : (ndc.x + 1) * viewport.width / 2,
      'y': ndc == null ? null : (1 - ndc.y) * viewport.height / 2,
      'pixelVisibility': 'unknown',
      'coordinateSpace': 'viewport-local logical pixels',
    };
  }
}

Map<String, T> _unique<T>(Iterable<T> values, String Function(T) id) {
  final result = <String, T>{};
  for (final value in values) {
    if (result.containsKey(id(value))) {
      throw ArgumentError('Duplicate view ID.');
    }
    result[id(value)] = value;
  }
  return Map.unmodifiable(result);
}
