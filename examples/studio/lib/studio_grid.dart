import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';

/// World-space guides stay outside authored content and cannot intercept picks.
class StudioGridPlugin extends ScenePlugin {
  @override
  String get id => 'studio.grid';
  @override
  Set<String> get dependencies => {'zyren.tools'};
  @override
  Set<RenderFeature> get requiredFeatures => {RenderFeature.portablePrimitives};
  final Group root = Group(name: 'Studio world grid');
  StudioGridPlugin() {
    for (final major in [false, true]) {
      final points = <Vec3>[];
      for (var i = -20; i <= 20; i++) {
        if (i == 0 || (i % 5 == 0) != major) continue;
        final value = i.toDouble();
        points.addAll([
          Vec3(-20, -1, value),
          Vec3(20, -1, value),
          Vec3(value, -1, -20),
          Vec3(value, -1, 20),
        ]);
      }
      root.add(
        Line(
          LineGeometry.segments(points: points),
          LineMaterial(
            color: Color3.hex(major ? 0x40515b : 0x263740),
            width: 1,
          ),
          name: major ? 'Major grid' : 'Minor grid',
        ),
      );
    }
    root.add(
      Line(
        LineGeometry(points: const [Vec3(-20, -1, 0), Vec3(20, -1, 0)]),
        LineMaterial(color: Color3.hex(0x805453)),
        name: 'X axis',
      ),
    );
    root.add(
      Line(
        LineGeometry(points: const [Vec3(0, -1, -20), Vec3(0, -1, 20)]),
        LineMaterial(color: Color3.hex(0x536e92)),
        name: 'Z axis',
      ),
    );
  }
  @override
  void attach(PluginContext context) {
    context.scene.add(root);
    context.scope.keep(context.service(sceneTools).excludeFromPicking(root));
  }

  @override
  void detach(PluginContext context) => root.parent?.remove(root);
}
