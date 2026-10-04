import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'local and global BRDF coverage allocates fallback only for uncovered PBR',
    () async {
      final backend = await NativeBackend.create();
      final probes = await ReflectionProbes.create(backend);
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
      final scene = Scene()..reflectionProbes = probes;
      final covered = scene.add(Mesh(PlaneGeometry(), StandardMaterial()));
      final outside = Mesh(PlaneGeometry(), StandardMaterial())
        ..position = const Vec3(2, 0, 0);
      Future<void> draw({Environment? global}) async {
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(32, 32),
            environment: global,
          ),
        );
      }

      bool hasTable(GpuInspection i) => i.allocations.any(
        (a) => a.kind == 'texture' && a.payloadBytes == 131072,
      );
      try {
        await probes.update(
          ReflectionProbeDescriptor(
            id: 0,
            position: Vec3.zero,
            bounds: Bounds3(-Vec3.one, Vec3.one),
            faceSize: 16,
            quality: const EnvironmentQuality(
              specularWidth: 16,
              diffuseWidth: 16,
              brdfSize: 16,
              samples: 64,
            ),
          ),
          scene: Scene()..background = const Color3(1, 1, 1),
          contentRevision: 1,
        );
        while (probes.pending) {
          await probes.advance();
        }
        await draw();
        expect(hasTable(await backend.inspectGpu()), isFalse);
        scene.add(outside);
        await draw(global: probes.environment(0));
        expect(hasTable(await backend.inspectGpu()), isFalse);
        await draw();
        var inspection = await backend.inspectGpu();
        expect(hasTable(inspection), isTrue);
        expect(inspection.frameProfile!.passes['energyLut']?.executed, isTrue);
        scene.remove(outside);
        await draw();
        inspection = await backend.inspectGpu();
        expect(inspection.frameProfile!.passes['energyLut']?.executed, isFalse);
        expect(hasTable(inspection), isTrue);
        scene.remove(covered);
        await draw();
        expect(hasTable(await backend.inspectGpu()), isFalse);
      } finally {
        await probes.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
