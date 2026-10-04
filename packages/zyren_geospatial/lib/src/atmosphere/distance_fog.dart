import 'package:zyren/zyren.dart';

/// A smooth distance fade in camera-relative metres, with a fully opaque end.
/// Install it through `AerialPerspectiveInputs` before using the same range to
/// cull geometry. The color is linear HDR radiance, before tone mapping.
final class GeoDistanceFog {
  final double startMetres, endMetres;
  final Color3 color;

  GeoDistanceFog({
    required this.startMetres,
    required this.endMetres,
    this.color = const Color3(.48, .57, .64),
  }) {
    if (!startMetres.isFinite ||
        !endMetres.isFinite ||
        startMetres < 0 ||
        endMetres <= startMetres ||
        endMetres - startMetres < .001 ||
        endMetres - startMetres < endMetres * 1e-6 ||
        endMetres > 1e8 ||
        color.toList().any((c) => !c.isFinite || c < 0 || c > 65504)) {
      throw ArgumentError(
        'Fog needs a finite 0 <= start < end <= 1e8, a representable fade of at least 1 mm and nonnegative HDR color.',
      );
    }
  }

  double opacityAt(double distanceMetres) {
    if (distanceMetres.isNaN || distanceMetres < 0) {
      throw ArgumentError.value(distanceMetres, 'distanceMetres');
    }
    final t = ((distanceMetres - startMetres) / (endMetres - startMetres))
        .clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Retains every sphere that touches the visible range, including its edge.
  /// Include animation/displacement and any morph envelope in [radiusMetres].
  bool intersectsVisibleRange(Vec3 camera, Vec3 center, double radiusMetres) {
    if (!camera.isFinite ||
        !center.isFinite ||
        !radiusMetres.isFinite ||
        radiusMetres < 0) {
      throw ArgumentError(
        'Fog culling requires finite positions and a nonnegative radius.',
      );
    }
    return camera.distanceTo(center) - radiusMetres <= endMetres * (1 + 1e-6);
  }
}
