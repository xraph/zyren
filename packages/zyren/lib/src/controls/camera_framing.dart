import 'dart:math' as math;
import '../math/vec3.dart';
import '../scene/scene.dart';
import '../spatial/bounds.dart';

/// Framing for the built-in perspective and orthographic cameras.
extension CameraFraming on Camera {
  /// Fits world [bounds] while retaining viewing direction, up and zoom.
  ///
  /// [aspect] uses logical viewport dimensions. [padding] is a scale of at
  /// least one; 1.2 leaves each projected half-extent within 1 / 1.2 of the
  /// viewport half-extent. [minimumExtent] gives point bounds a finite size.
  /// Clip planes are fitted to the result. Empty bounds return false.
  /// Invalid or unrepresentable results throw before changing the camera.
  bool frameBounds(
    Bounds3 bounds, {
    required double aspect,
    double padding = 1.15,
    double minimumExtent = .01,
  }) {
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !padding.isFinite ||
        padding < 1 ||
        !minimumExtent.isFinite ||
        minimumExtent <= 0) {
      throw ArgumentError(
        'Framing needs positive finite aspect/extent and padding >= 1.',
      );
    }
    if (this is! PerspectiveCamera && this is! OrthographicCamera) {
      throw UnsupportedError('Framing requires a built-in camera projection.');
    }
    if (bounds.isEmpty) return false;
    viewProjection(aspect);
    final backward = (position - target).normalized();
    final right = up.cross(backward).normalized();
    final vertical = backward.cross(right);
    final center = bounds.center;
    final points = [
      for (final corner in bounds.corners)
        Vec3(
          (corner - center).dot(right),
          (corner - center).dot(vertical),
          (corner - center).dot(backward),
        ),
    ];
    var minZ = double.infinity, maxZ = double.negativeInfinity;
    var halfWidth = minimumExtent / 2, halfHeight = minimumExtent / 2;
    for (final p in points) {
      if (!p.isFinite) {
        throw ArgumentError('Framing bounds exceed finite coordinates.');
      }
      minZ = math.min(minZ, p.z);
      maxZ = math.max(maxZ, p.z);
      halfWidth = math.max(halfWidth, p.x.abs());
      halfHeight = math.max(halfHeight, p.y.abs());
    }
    final margin = math.max(minimumExtent / 2, (maxZ - minZ) * .05);
    var distance = maxZ + margin;
    double? verticalSize;
    if (this case PerspectiveCamera(:final fieldOfView)) {
      final tanY = math.tan(fieldOfView / 2), tanX = tanY * aspect;
      // The synthetic center extent also gives points and thin lines a useful
      // framing distance, without expanding the actual clip bounds.
      distance = math.max(
        distance,
        padding * minimumExtent / (2 * math.min(tanX, tanY)),
      );
      for (final p in points) {
        distance = math.max(
          distance,
          p.z + padding * math.max(p.x.abs() / tanX, p.y.abs() / tanY),
        );
      }
    } else if (this case OrthographicCamera(:final zoom)) {
      verticalSize =
          2 * padding * math.max(halfHeight, halfWidth / aspect) * zoom;
      distance = math.max(distance, position.distanceTo(target));
    }
    final nextPosition = center + backward * distance;
    final near = (distance - maxZ) * .5;
    final far = distance - minZ + margin;
    // Constructing a candidate validates clipping, aspect and representable
    // direction at large origins before any observable setter is touched.
    final Camera candidate = switch (this) {
      PerspectiveCamera(:final fieldOfView) => PerspectiveCamera(
        position: nextPosition,
        target: center,
        up: up,
        fieldOfView: fieldOfView,
        near: near,
        far: far,
      ),
      OrthographicCamera(:final zoom) => OrthographicCamera(
        position: nextPosition,
        target: center,
        up: up,
        verticalSize: verticalSize!,
        zoom: zoom,
        near: near,
        far: far,
      ),
      _ => throw StateError('Unsupported framing projection.'),
    };
    candidate.viewProjection(aspect);
    position = nextPosition;
    target = center;
    switch (this) {
      case PerspectiveCamera camera:
        if (near >= camera.far) camera.far = far;
        camera.near = near;
        camera.far = far;
      case OrthographicCamera camera:
        if (near >= camera.far) camera.far = far;
        camera.near = near;
        camera.far = far;
        camera.verticalSize = verticalSize!;
    }
    return true;
  }
}
