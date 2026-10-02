import 'package:flutter_zyren/flutter_zyren.dart';

Iterable<Object3D> _descendants(Object3D object) sync* {
  for (final child in object.children) {
    yield child;
    yield* _descendants(child);
  }
}

/// Reference radius of the example's two-unit gizmo after visual scaling.
double workbenchGizmoRadius(SceneController controller) =>
    2 *
    _descendants(
      controller.scene,
    ).firstWhere((object) => object.name == 'Handle visuals').scale.x;
