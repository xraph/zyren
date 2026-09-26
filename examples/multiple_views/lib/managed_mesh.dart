import 'package:flutter/widgets.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

/// The view creates and disposes its controller. Rebuilds retain this scene.
class ManagedMesh extends StatelessWidget {
  final SceneRuntime? runtime;
  const ManagedMesh({super.key, this.runtime});
  @override
  Widget build(BuildContext context) => SceneView.builder(
    sceneKey: 'managed-mesh',
    runtime: runtime,
    options: const EngineOptions(presentation: PresentationPolicy.readbackOnly),
    onCreate: (controller) {
      final mesh = controller.scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.95, .46, .18))),
      );
      controller.onUpdate(
        (time) => mesh.rotateY(time.delta.inMicroseconds / 1000000),
      );
    },
  );
}
