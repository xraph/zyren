import 'dart:math' as math;
import 'package:zyren/zyren.dart';

InstancedMesh populateInstances(Scene scene) {
  scene.background = const Color3(.018, .027, .046);
  scene.add(DirectionalLight(intensity: 2)..lookAt(const Vec3(-.4, -1, -.3)));
  scene.add(
    HemisphereLight(
      skyColor: const Color3(.5, .65, .9),
      groundColor: const Color3(.15, .12, .1),
      intensity: .7,
    ),
  );
  final instances = scene.add(
    InstancedMesh(
      BoxGeometry(width: .6, height: .6, depth: .6),
      StandardMaterial(
        baseColor: const Color3(.1, .55, .8),
        roughness: .45,
        metallic: .15,
      ),
      count: 10000,
    ),
  );
  instances.setTransforms(0, List.generate(10000, (i) => instanceTransform(i)));
  return instances;
}

Mat4 instanceTransform(int i) => Mat4.compose(
  Vec3((i % 100) - 49.5, math.sin(i * .019) * 1.2, (i ~/ 100) - 49.5),
  Quat.axisAngle(const Vec3(0, 1, 0), i * .07),
  Vec3(i.isEven ? -1 : 1, 1 + (i % 7) * .15, 1),
);
