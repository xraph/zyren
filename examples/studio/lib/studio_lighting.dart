import 'package:flutter_zyren/flutter_zyren.dart';

/// Host lighting stays outside authored content and is identical in previews.
void addStudioLighting(Scene scene) {
  scene.add(
    Group(name: 'Studio preview lighting')
      ..add(
        DirectionalLight(intensity: 3)
          ..rotateY(-.5)
          ..rotateX(-.5),
      )
      ..add(
        HemisphereLight(
          intensity: .7,
          groundColor: const Color3(.15, .18, .25),
        ),
      ),
  );
}
