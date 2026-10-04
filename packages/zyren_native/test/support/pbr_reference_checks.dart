import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'brdf_reference.dart';
import 'linear_scene_probe.dart';
import 'environment_checks.dart' show constantEnvironment;

Future<void> verifyPbrReference(NativeGpuBackend backend) async {
  final probe = await LinearSceneProbe.create(backend);
  final scene = Scene()..background = const Color3(0, 0, 0);
  final mesh = scene.add(
    Mesh(PlaneGeometry(width: 20, height: 20), StandardMaterial()),
  );
  final sun = scene.add(DirectionalLight());
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
  const base = Color3(.8, .3, .05);
  Vec3 direction(double degrees, double azimuth) {
    final angle = degrees * math.pi / 180;
    return Vec3(
      math.sin(angle) * math.cos(azimuth),
      math.sin(angle) * math.sin(azimuth),
      math.cos(angle),
    );
  }

  try {
    for (final (viewAngle, lightAngle, azimuth) in [
      (0.0, 0.0, 0.0),
      (0.0, 37.0, 0.0),
      (35.0, 52.0, 1.2),
      (65.0, 70.0, 2.0),
      (40.0, 40.0, math.pi),
    ]) {
      final v = direction(viewAngle, 0), l = direction(lightAngle, azimuth);
      camera.position = v * 3;
      sun.lookAt(-l);
      for (final roughness in [0.0, .045, .1, .3, .65, 1.0]) {
        for (final metallic in [0.0, .25, .5, .75, 1.0]) {
          mesh.material = StandardMaterial(
            baseColor: base,
            metallic: metallic,
            roughness: roughness,
          );
          final actual = await probe.draw(scene, camera);
          final expected = referenceRadiance(
            view: v,
            light: l,
            base: base,
            metallic: metallic,
            roughness: roughness,
          );
          for (var channel = 0; channel < 3; channel++) {
            expect(
              actual[channel],
              closeTo(
                expected[channel],
                math.max(2e-5, expected[channel] * .003),
              ),
              reason:
                  'view=$viewAngle light=$lightAngle azimuth=$azimuth roughness=$roughness metallic=$metallic channel=$channel',
            );
          }
          expect(actual[3], 1);
        }
      }
    }
    sun.visible = false;
    final map = await EnvironmentMap.fromEquirectangular(
      constantEnvironment(1, .5, .25),
      resources: probe.resources,
      quality: const EnvironmentQuality(
        specularWidth: 16,
        diffuseWidth: 16,
        brdfSize: 128,
        samples: 2048,
      ),
    );
    try {
      for (final angle in [0.0, 55.0, 80.0]) {
        camera.position = direction(angle, 0) * 3;
        for (final roughness in [.1, .6, 1.0]) {
          final samples = <List<double>>[];
          for (final metallic in [0.0, .25, .5, .75, 1.0]) {
            mesh.material = StandardMaterial(
              baseColor: base,
              metallic: metallic,
              roughness: roughness,
            );
            samples.add(
              await probe.draw(
                scene,
                camera,
                environment: Environment(map: map),
              ),
            );
          }
          final (a, b) = referenceDirectionalEnergy(
            math.cos(angle * math.pi / 180),
            roughness,
          );
          final whiteEnergy = a + b;
          final dielectricEnergy =
              (.04 * a + b) * (1 + .04 * (1 / whiteEnergy - 1));
          for (var index = 0; index < samples.length; index++) {
            final weight = index * .25;
            for (var c = 0; c < 3; c++) {
              final color = [base.r, base.g, base.b][c];
              final f0 = .04 * (1 - weight) + color * weight;
              final reflected = (f0 * a + b) * (1 + f0 * (1 / whiteEnergy - 1));
              final expected =
                  ((1 - weight) * (1 - dielectricEnergy) * color + reflected) *
                  [1.0, .5, .25][c];
              expect(
                samples[index][c],
                closeTo(expected, math.max(3e-4, expected * .025)),
                reason:
                    'integrated IBL angle=$angle roughness=$roughness metallic=$weight channel=$c',
              );
            }
          }
        }
      }
    } finally {
      await map.close();
    }
  } finally {
    await probe.close();
  }
}
