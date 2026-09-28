part of 'scene.dart';

/// An inner edge along selected objects' visible native coverage.
final class SceneOutline {
  final Set<Object3D> objects;
  final Color3 color;

  /// Width in physical pixels, from one to eight.
  final int width;
  final double opacity;
  SceneOutline({
    required Iterable<Object3D> objects,
    Color3? color,
    this.width = 2,
    this.opacity = 1,
  }) : objects = Set.unmodifiable(objects),
       color = color ?? Color3.hex(0xf2bd65) {
    this.color.toList();
    if (width < 1 ||
        width > 8 ||
        !opacity.isFinite ||
        opacity < 0 ||
        opacity > 1) {
      throw ArgumentError('Invalid outline width or opacity.');
    }
  }
}
