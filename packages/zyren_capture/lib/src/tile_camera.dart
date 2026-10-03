import 'package:zyren/zyren.dart';

/// Crops a perspective frustum in clip space without changing the camera pose.
final class TileCamera extends PerspectiveCamera {
  final int fullWidth, fullHeight, x, y, width, height;
  TileCamera(
    PerspectiveCamera camera, {
    required this.fullWidth,
    required this.fullHeight,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  }) : super(
         position: camera.position,
         target: camera.target,
         up: camera.up,
         fieldOfView: camera.fieldOfView,
         near: camera.near,
         far: camera.far,
         zoom: camera.zoom,
         depthStrategy: camera.depthStrategy,
       );
  @override
  Mat4 projectionMatrix(double aspect) {
    final crop = Mat4([
      fullWidth / width,
      0,
      0,
      0,
      0,
      fullHeight / height,
      0,
      0,
      0,
      0,
      1,
      0,
      (fullWidth - 2 * x - width) / width,
      (2 * y + height - fullHeight) / height,
      0,
      1,
    ]);
    return crop * super.projectionMatrix(fullWidth / fullHeight);
  }
}
