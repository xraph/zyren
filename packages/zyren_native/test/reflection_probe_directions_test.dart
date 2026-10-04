import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'scene_admission_test.dart' show largeGeometry;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'six capture cameras preserve far-world opposite directions and opaque radiance',
    () async {
      final backend = await NativeBackend.create();
      final secondary = backend.createView();
      final probes = await ReflectionProbes.create(backend);
      final reader = backend.createResourceScope();
      const origin = Vec3(1e12, 0, 0);
      final scene = Scene()..ambient = 0;
      scene.add(
        Mesh(
            PlaneGeometry(width: 10, height: 10),
            StandardMaterial(
              baseColor: const Color3(0, 0, 0),
              emissive: const Color3(1, 0, 0),
              emissiveIntensity: 8,
              opacity: .5,
              alphaMode: MaterialAlphaMode.blend,
            ),
          )
          ..position = origin + const Vec3(2, 0, 0)
          ..rotateY(math.pi / 2),
      );
      scene.add(
        Mesh(
            PlaneGeometry(width: 10, height: 10),
            StandardMaterial(
              baseColor: const Color3(0, 0, 0),
              emissive: const Color3(0, 1, 0),
              emissiveIntensity: 8,
            ),
          )
          ..position = origin + const Vec3(-2, 0, 0)
          ..rotateY(math.pi / 2),
      );
      final d = ReflectionProbeDescriptor(
        id: 0,
        position: origin,
        bounds: Bounds3(
          origin - const Vec3(3, 3, 3),
          origin + const Vec3(3, 3, 3),
        ),
        faceSize: 16,
        quality: const EnvironmentQuality(
          specularWidth: 16,
          diffuseWidth: 16,
          brdfSize: 16,
          samples: 64,
        ),
      );
      try {
        await probes.update(d, scene: scene, contentRevision: 1);
        // Camera movement elsewhere does not alter the six latched captures.
        final camera = PerspectiveCamera(
          position: origin + const Vec3(0, 0, 4),
          target: origin,
        );
        while (probes.pending) {
          camera.position = camera.position + const Vec3(.001, 0, 0);
          await probes.advance();
        }
        final map = probes.environment(0)!.map;
        final data = ByteData.sublistView(
          await reader.readTexture(await reader.retain(map.specular)),
        );
        final px = (4 * 16 + 8) * 8, nx = (4 * 16) * 8;
        expect(data.getUint16(px, Endian.little), closeTo(0x4400, 4));
        expect(data.getUint16(px + 2, Endian.little), 0);
        expect(data.getUint16(nx + 2, Endian.little), closeTo(0x4800, 4));
        final main = Scene()
          ..ambient = 0
          ..reflectionProbes = probes;
        main.add(
          Mesh(PlaneGeometry(width: 2, height: 2), StandardMaterial())
            ..position = origin,
        );
        for (final view in [backend, secondary]) {
          final frame = await view.render(
            FrameSubmission.capture(
              scene: main,
              camera: camera,
              size: PhysicalSize(16, 16),
            ),
          );
          expect(frame.stats.admission!.candidateReady, isTrue);
        }
        final old = probes.environment(0);
        await probes.update(d, scene: scene, contentRevision: 2);
        while (probes.pending) {
          await probes.advance();
        }
        expect(probes.retainedGenerations, 1);
        // Both inactive views retain the previous complete cover until replacement.
        expect(old!.map.isClosed, isTrue);
        // The old cover keeps its latched per-mesh probe while its world origin
        // is reprojected during a larger scene replacement.
        backend.configureSceneUploadBudget(1024);
        final replacement = Scene()..reflectionProbes = probes;
        for (var i = 0; i < 3; i++) {
          replacement.add(
            Mesh(largeGeometry(300), StandardMaterial())..position = origin,
          );
        }
        camera.position = origin + const Vec3(.1, 0, 4);
        final staged = await backend.render(
          FrameSubmission.capture(
            scene: replacement,
            camera: camera,
            size: PhysicalSize(24, 16),
          ),
        );
        expect(staged.stats.admission!.candidateReady, isFalse);
        await probes.reclaim();
        expect(probes.retainedGenerations, 1);
        backend.configureSceneUploadBudget(16777216);
        await backend.render(
          FrameSubmission.capture(
            scene: main,
            camera: camera,
            size: PhysicalSize(24, 16),
          ),
        );
        await probes.reclaim();
        expect(probes.retainedGenerations, 1);
        await secondary.close();
        await reader.close();
        await probes.reclaim();
        expect(probes.retainedGenerations, 0);
      } finally {
        await secondary.close();
        await reader.close();
        await probes.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
