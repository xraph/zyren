import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/linear_scene_probe.dart';
import 'support/environment_checks.dart' show constantEnvironment;
import 'support/brdf_reference.dart';

void main() {
  test('linear HDR furnace restores isotropic energy and retains absorption', () async {
    final backend = await NativeBackend.create();
    final probe = await LinearSceneProbe.create(backend);
    final scene = Scene();
    final plane = PlaneGeometry(width: 40, height: 40);
    final geometry = BufferGeometry.fromAttributes(
      attributes: {
        ...plane.attributes,
        VertexSemantic.tangent: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < 4; i++) ...[1, 0, 0, 1],
          ]),
          format: VertexFormat.float32x4,
        ),
      },
      indices: plane.indices,
    );
    final mesh = scene.add(Mesh(geometry, StandardMaterial()));
    final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
    final environment = await EnvironmentMap.fromEquirectangular(
      constantEnvironment(2, 2, 2),
      resources: probe.resources,
      quality: const EnvironmentQuality(
        specularWidth: 16,
        diffuseWidth: 16,
        brdfSize: 128,
        samples: 2048,
      ),
    );
    try {
      for (final degrees in [0.0, 60.0, 85.0]) {
        final angle = degrees * math.pi / 180;
        camera.position = Vec3(math.sin(angle), 0, math.cos(angle)) * 3;
        for (final roughness in [0.0, .3, .65, 1.0]) {
          for (final metallic in [0.0, 1.0]) {
            mesh.material = StandardMaterial(
              roughness: roughness,
              metallic: metallic,
            );
            final value = await probe.draw(
              scene,
              camera,
              environment: Environment(map: environment),
            );
            for (final channel in value.take(3)) {
              expect(
                channel,
                closeTo(2, .015),
                reason:
                    'unclamped furnace view=$degrees roughness=$roughness metal=$metallic',
              );
            }
          }
          mesh.material = StandardMaterial(
            baseColor: const Color3(.8, .3, .05),
            roughness: roughness,
            metallic: 1,
          );
          final value = await probe.draw(
            scene,
            camera,
            environment: Environment(map: environment),
          );
          final (a, b) = referenceDirectionalEnergy(math.cos(angle), roughness);
          for (var c = 0; c < 3; c++) {
            final f0 = [.8, .3, .05][c];
            final expected = 2 * (f0 * a + b) * (1 + f0 * (1 / (a + b) - 1));
            expect(
              value[c],
              closeTo(expected, math.max(.002, expected * .015)),
            );
            expect(value[c], lessThan(2));
          }
          mesh.material = PhysicalMaterial(metallic: 1, roughness: roughness);
          final physical = await probe.draw(
            scene,
            camera,
            environment: Environment(map: environment),
          );
          for (final channel in physical.take(3)) {
            expect(channel, closeTo(2, .015));
          }
        }
      }
      for (final degrees in [0.0, 60.0, 85.0]) {
        final angle = degrees * math.pi / 180;
        camera.position = Vec3(math.sin(angle), 0, math.cos(angle)) * 3;
        for (final material in [
          PhysicalMaterial(metallic: 1, roughness: .65, anisotropy: .8),
          PhysicalMaterial(
            roughness: .65,
            clearcoat: 1,
            clearcoatRoughness: .5,
            sheenColor: const Color3(.6, .4, .2),
          ),
          PhysicalMaterial(
            roughness: .65,
            iridescence: 1,
            iridescenceThicknessMaximum: 400,
            clearcoat: .5,
          ),
        ]) {
          mesh.material = material;
          final energy = await probe.draw(
            scene,
            camera,
            environment: Environment(map: environment),
          );
          for (final channel in energy.take(3)) {
            expect(channel, inInclusiveRange(0, 2.02));
          }
        }
      }
      // Integrate actual shader responses to an independently chosen uniform
      // solid-angle grid. The reference uses visible normals and a different PDF.
      for (final (degrees, roughness, anisotropy, azimuth) in [
        (0.0, .65, 0.0, 0.0),
        (0.0, 1.0, 0.0, 0.0),
        (60.0, .65, 0.0, 0.0),
        (60.0, 1.0, 0.0, 0.0),
        (60.0, .65, .8, 0.0),
        (60.0, .65, .8, math.pi / 2),
        (85.0, .65, .8, 0.0),
        (85.0, .65, .8, math.pi / 2),
      ]) {
        final angle = degrees * math.pi / 180, nv = math.cos(angle);
        camera.position = Vec3(math.sin(angle), 0, nv) * 3;
        mesh.material = PhysicalMaterial(
          metallic: 1,
          roughness: roughness,
          anisotropy: anisotropy,
          anisotropyRotation: azimuth,
        );
        final total = await integrateNative(probe, scene, camera);
        final (a, b) = referenceDirectionalEnergy(
          nv,
          roughness,
          anisotropy: anisotropy,
          azimuth: azimuth,
        );
        final alpha = roughness * roughness;
        final effective = math.sqrt(
          math.sqrt(alpha * (alpha + (1 - alpha) * anisotropy * anisotropy)),
        );
        final (ea, eb) = referenceDirectionalEnergy(nv, effective);
        final expected = (a + b) / (ea + eb);
        for (final channel in total) {
          expect(
            channel,
            closeTo(expected, .01),
            reason:
                'native directional energy view=$degrees r=$roughness anisotropy=$anisotropy azimuth=$azimuth',
          );
        }
        print(
          'direct furnace view=$degrees r=$roughness anisotropy=$anisotropy azimuth=$azimuth measured=${total[0]} reference=$expected',
        );
      }
      for (final thickness in [250.0, 400.0]) {
        camera.position = const Vec3(0, 0, 3);
        mesh.material = PhysicalMaterial(
          roughness: .65,
          iridescence: 1,
          iridescenceThicknessMaximum: thickness,
          clearcoat: .5,
          clearcoatRoughness: .5,
        );
        final total = await integrateNative(probe, scene, camera);
        print('layered thin-film furnace thickness=$thickness energy=$total');
        for (final channel in total) {
          expect(channel, inInclusiveRange(0, 1.08));
        }
      }
      camera.position = const Vec3(0, 0, 3);
      final area = scene.add(
        RectAreaLight(width: 2, height: 2)..position = const Vec3(0, 0, 2),
      );
      for (final roughness in [.35, .65, 1.0]) {
        mesh.material = StandardMaterial(metallic: 1, roughness: roughness);
        final actual = (await probe.draw(scene, camera))[0];
        var expected = 0.0;
        const steps = 128;
        for (var y = 0; y < steps; y++) {
          for (var x = 0; x < steps; x++) {
            final offset = Vec3(
              2 * (x + .5) / steps - 1,
              2 * (y + .5) / steps - 1,
              2,
            );
            final distance2 = offset.dot(offset),
                direction = offset.normalized();
            expected +=
                referenceRadiance(
                  view: const Vec3(0, 0, 1),
                  light: direction,
                  base: const Color3(1, 1, 1),
                  metallic: 1,
                  roughness: roughness,
                )[0] *
                direction.z /
                distance2 *
                4 /
                (steps * steps);
          }
        }
        print(
          'LTC HDR roughness=$roughness actual=$actual quadrature=$expected',
        );
        expect(actual, closeTo(expected, math.max(.002, expected * .04)));
      }
      scene.remove(area);
    } finally {
      await environment.close();
      await probe.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}

Future<List<double>> integrateNative(
  LinearSceneProbe probe,
  Scene scene,
  PerspectiveCamera camera,
) async {
  final lights = List.generate(16, (_) => scene.add(DirectionalLight()));
  final total = [0.0, 0.0, 0.0];
  const zSteps = 32, phiSteps = 64;
  try {
    for (var batch = 0; batch < zSteps * phiSteps ~/ 16; batch++) {
      for (var i = 0; i < 16; i++) {
        final sample = batch * 16 + i;
        final z = (sample ~/ phiSteps + .5) / zSteps;
        final phi = (sample % phiSteps + .5) * 2 * math.pi / phiSteps;
        final radial = math.sqrt(1 - z * z);
        lights[i].direction = Vec3(
          -radial * math.cos(phi),
          -radial * math.sin(phi),
          -z,
        );
        lights[i].intensity = 2 * math.pi / (zSteps * phiSteps);
      }
      final response = await probe.draw(scene, camera);
      for (var c = 0; c < 3; c++) {
        total[c] += response[c];
      }
    }
  } finally {
    for (final light in lights) {
      scene.remove(light);
    }
  }
  return total;
}
