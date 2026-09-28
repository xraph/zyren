import 'package:zyren/zyren.dart';

/// Run with `dart run example/camera_transition.dart` from the zyren package.
/// In a viewport, assign transitions.camera after each elapsed-time update.
void main() {
  final transitions = CameraTransitionManager(
    PerspectiveCamera(position: const Vec3(0, 0, 100), far: 100000),
    OrthographicCamera(left: -3, right: 3, top: 2, bottom: -2, far: 100000),
  )..fixedPoint = const Vec3(2, 3, 0);
  transitions.toggle();
  while (transitions.needsUpdate) {
    transitions.update(1 / 60);
    final camera = transitions.camera;
    final fixed = camera.projectPoint(transitions.fixedPoint, 1.5);
    print('${transitions.alpha.toStringAsFixed(3)}: ${fixed.x}, ${fixed.y}');
  }
  transitions.dispose();
}
