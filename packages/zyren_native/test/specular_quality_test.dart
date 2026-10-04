import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/linear_scene_probe.dart';
import 'support/environment_checks.dart' show constantEnvironment;

void main() {
  test(
    'mapped specular AA filters motion and preserves disabled roughness',
    () async {
      final backend = await NativeBackend.create();
      final evidence = Platform.environment['ZYREN_QUALITY_EVIDENCE'];
      if (evidence != null && Platform.isMacOS) {
        final loaded = await Process.run('lsof', ['-p', '$pid', '-Fn']);
        final paths = loaded.stdout
            .toString()
            .split('\n')
            .where(
              (line) =>
                  line.startsWith('n') &&
                  line.contains('libzyren_runtime') &&
                  line.endsWith('.dylib'),
            )
            .map((line) => line.substring(1))
            .toSet();
        final identity = <String>[];
        for (final path in paths) {
          final hash = await Process.run('shasum', ['-a', '256', path]);
          identity.add(hash.stdout.toString().trim());
        }
        File(
          '$evidence/loaded-native-artifact.txt',
        ).writeAsStringSync(identity.join('\n'));
        print('loaded native artifact: $identity');
      }
      final probe = await LinearSceneProbe.create(backend);
      final plane = PlaneGeometry(width: 12, height: 12);
      final geometry = BufferGeometry.fromAttributes(
        attributes: {
          ...plane.attributes,
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 4; i++) ...[1, 0, 0, -1],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: plane.indices,
      );
      final bytes = <int>[];
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          final nx = .6 * math.sin(x * math.pi / 2),
              ny = .35 * math.cos(y * math.pi / 2);
          bytes.addAll([
            ((nx + 1) * 127.5).round(),
            ((ny + 1) * 127.5).round(),
            ((math.sqrt(1 - nx * nx - ny * ny) + 1) * 127.5).round(),
            255,
          ]);
        }
      }
      final normal = TextureMap(
        image: TextureImage.rgba(
          width: 128,
          height: 128,
          pixels: Uint8List.fromList(bytes),
          format: TextureFormat.rgba8Unorm,
        ),
      );
      final scene = Scene();
      final mesh = scene.add(Mesh(geometry, StandardMaterial()));
      final sun = scene.add(DirectionalLight(intensity: 3));
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      try {
        for (final grazing in [false, true]) {
          for (final layered in [false, true]) {
            final angle = grazing ? 70 * math.pi / 180 : 0.0;
            sun.quaternion = Quat.axisAngle(const Vec3(0, 1, 0), -angle);
            StandardMaterial material(double variance, double threshold) =>
                layered
                ? PhysicalMaterial(
                    metallic: 1,
                    roughness: .15,
                    normalMap: normal,
                    clearcoat: .5,
                    clearcoatRoughness: .12,
                    clearcoatNormalMap: normal,
                    anisotropy: .6,
                    specularAntiAliasingVariance: variance,
                    specularAntiAliasingThreshold: threshold,
                  )
                : StandardMaterial(
                    metallic: 1,
                    roughness: .15,
                    normalMap: normal,
                    specularAntiAliasingVariance: variance,
                    specularAntiAliasingThreshold: threshold,
                  );
            final sequences = <List<List<double>>>[];
            for (final enabled in [false, true]) {
              mesh.material = material(enabled ? .15 : 0, .2);
              final frames = <List<double>>[];
              for (var i = 0; i < 12; i++) {
                camera.position = Vec3(
                  math.sin(angle) * 3 + i * .006,
                  0,
                  math.cos(angle) * 3,
                );
                frames.add(await probe.drawPixels(scene, camera));
              }
              sequences.add(frames);
            }
            double motion(List<List<double>> frames) {
              var error = 0.0;
              for (var i = 1; i < frames.length; i++) {
                for (var j = 0; j < frames[i].length; j += 4) {
                  error += (frames[i][j] - frames[i - 1][j]).abs();
                }
              }
              return error / ((frames.length - 1) * 31 * 31);
            }

            double mean(List<List<double>> frames) =>
                frames.fold(
                  0.0,
                  (sum, frame) =>
                      sum +
                      [
                        for (var i = 0; i < frame.length; i += 4)
                          .2126 * frame[i] +
                              .7152 * frame[i + 1] +
                              .0722 * frame[i + 2],
                      ].fold(0.0, (a, b) => a + b),
                ) /
                (frames.length * 31 * 31);
            final off = motion(sequences[0]), on = motion(sequences[1]);
            final offMean = mean(sequences[0]), onMean = mean(sequences[1]);
            print(
              'normal motion grazing=$grazing layered=$layered off=$off on=$on ratio=${on / off} meanOff=$offMean meanOn=$onMean normalizedOff=${off / offMean} normalizedOn=${on / onMean}',
            );
            expect(on, lessThan(off));
            expect(on / onMean, lessThan(off / offMean));
            final evidence = Platform.environment['ZYREN_QUALITY_EVIDENCE'];
            if (evidence != null) {
              File(
                '$evidence/normal-motion-$grazing-$layered.json',
              ).writeAsStringSync(
                jsonEncode({
                  'width': 31,
                  'height': 31,
                  'format': 'linear HDR RGBA',
                  'offMotion': off,
                  'offMeanLuminance': offMean,
                  'onMeanLuminance': onMean,
                  'settings': {
                    'variance': .15,
                    'threshold': .2,
                    'roughness': .15,
                    'coat': layered ? .5 : 0,
                    'coatRoughness': .12,
                    'anisotropy': layered ? .6 : 0,
                    'cameraStep': .006,
                    'grazingDegrees': grazing ? 70 : 0,
                    'normalTexture': 128,
                    'normalPeriodTexels': 4,
                    'mipmaps': false,
                  },
                  'onMotion': on,
                  'frames': sequences,
                }),
              );
            }
            mesh.material = material(.15, 0);
            final disabledThreshold = await probe.drawPixels(scene, camera);
            expect(
              disabledThreshold,
              sequences[0].last,
              reason: 'either zero gives exact original roughness',
            );
            mesh.material = material(0, .2);
            final standard = await probe.drawPixels(scene, camera);
            if (!layered) {
              mesh.material = PhysicalMaterial(
                metallic: 1,
                roughness: .15,
                normalMap: normal,
                specularAntiAliasingVariance: 0,
              );
              final inactive = await probe.drawPixels(scene, camera);
              var maximumAbsolute = 0.0, maximumRelative = 0.0;
              for (var i = 0; i < inactive.length; i++) {
                final difference = (inactive[i] - standard[i]).abs();
                maximumAbsolute = math.max(maximumAbsolute, difference);
                maximumRelative = math.max(
                  maximumRelative,
                  difference / math.max(standard[i], 1e-6),
                );
                expect(
                  inactive[i],
                  closeTo(standard[i], math.max(1e-6, standard[i] * .0015)),
                  reason: 'inactive layers agree within half-float rounding',
                );
              }
              print(
                'inactive quantization grazing=$grazing maxAbsolute=$maximumAbsolute maxRelative=$maximumRelative',
              );
            }
          }
        }
        // A constant normal has zero variance and must not blur the highlight.
        camera.position = const Vec3(0, 0, 3);
        sun.quaternion = Quat.identity;
        mesh.material = StandardMaterial(metallic: 1, roughness: .2);
        final flat = await probe.drawPixels(scene, camera);
        mesh.material = StandardMaterial(
          metallic: 1,
          roughness: .2,
          specularAntiAliasingVariance: 0,
        );
        expect(await probe.drawPixels(scene, camera), flat);
      } finally {
        await probe.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'specular occlusion depends on view and roughness only for indirect light',
    () async {
      final backend = await NativeBackend.create();
      final probe = await LinearSceneProbe.create(backend);
      final scene = Scene();
      final mesh = scene.add(
        Mesh(PlaneGeometry(width: 40, height: 40), StandardMaterial()),
      );
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      final ao = TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList([128, 128, 128, 255]),
          format: TextureFormat.rgba8Unorm,
        ),
      );
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
        for (final roughness in [.1, .8]) {
          for (final nv in [1.0, .2]) {
            camera.position = Vec3(math.sqrt(1 - nv * nv), 0, nv) * 3;
            mesh.material = StandardMaterial(
              metallic: 1,
              roughness: roughness,
              occlusionMap: ao,
            );
            final value = await probe.draw(
              scene,
              camera,
              environment: Environment(map: environment),
            );
            final occlusion =
                (math.pow(nv + 128 / 255, math.pow(2, -16 * roughness - 1)) -
                        1 +
                        128 / 255)
                    .clamp(0, 1);
            expect(value[0], closeTo(2 * occlusion, .02));
          }
        }
        scene.add(DirectionalLight());
        mesh.material = StandardMaterial(
          metallic: 1,
          roughness: .4,
          occlusionMap: ao,
        );
        final direct = await probe.draw(scene, camera);
        mesh.material = StandardMaterial(metallic: 1, roughness: .4);
        expect(await probe.draw(scene, camera), direct);
      } finally {
        await probe.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
