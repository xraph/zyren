import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';

/// A small scene you can attach to a native engine or a Flutter SceneController.
({
  Scene scene,
  PerspectiveCamera camera,
  SceneDevtoolsPlugin inspector,
  SceneDiagnostics diagnostics,
})
inspectionRecipe() {
  final scene = Scene();
  scene.add(
    Mesh(
      BoxGeometry(),
      UnlitMaterial(color: Color3.hex(0x47b5ad)),
      name: 'Cube',
    ),
  );
  final camera = PerspectiveCamera(position: const Vec3(3, 2, 5));
  final inspector = SceneDevtoolsPlugin(historyLimit: 120);
  return (
    scene: scene,
    camera: camera,
    inspector: inspector,
    diagnostics: SceneDiagnostics(inspector),
  );
}
