import 'dart:math' as math;

/// Keeps the native canvas within its capture budget without resizing the UI.
double oceanResolutionScale({
  required double width,
  required double height,
  required double devicePixelRatio,
  required int maxPixels,
}) {
  if (!width.isFinite ||
      !height.isFinite ||
      !devicePixelRatio.isFinite ||
      width <= 0 ||
      height <= 0 ||
      devicePixelRatio <= 0 ||
      maxPixels < 1) {
    throw ArgumentError(
      'Expected a finite viewport and positive pixel budget.',
    );
  }
  final nativePixels = width * height * devicePixelRatio * devicePixelRatio;
  if (nativePixels <= maxPixels) return 1;
  final ratio = math.sqrt(maxPixels / (width * height));
  // SceneView rounds each dimension. Floor the targets before choosing a common
  // ratio so that rounding cannot exceed the admitted pixel count.
  final targetWidth = math.max(1, (width * ratio).floor());
  final targetHeight = math.max(1, (height * ratio).floor());
  return math.min(targetWidth / width, targetHeight / height) /
      devicePixelRatio;
}
