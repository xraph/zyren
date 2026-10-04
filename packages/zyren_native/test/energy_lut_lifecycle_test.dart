import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/environment_checks.dart' show constantEnvironment;

void main() {
  test(
    'supplied BRDF avoids fallback allocation and preserves later warm ownership',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      final fill = resources.createChild();
      EnvironmentMap? map;
      try {
        map = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(1, 1, 1),
          resources: resources,
          quality: const EnvironmentQuality(
            specularWidth: 16,
            diffuseWidth: 16,
            brdfSize: 16,
            samples: 64,
          ),
        );
        final scene = Scene()
          ..add(
            Mesh(
              PlaneGeometry(width: 2, height: 2),
              StandardMaterial(metallic: 1, roughness: .6),
            ),
          );
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        Future<void> draw(Scene content, {bool supplied = true}) async {
          await backend.render(
            FrameSubmission.capture(
              scene: content,
              camera: camera,
              size: PhysicalSize(31, 31),
              environment: supplied ? Environment(map: map!) : null,
            ),
          );
        }

        bool hasTable(GpuInspection inspection) => inspection.allocations.any(
          (a) => a.kind == 'texture' && a.payloadBytes == 131072,
        );
        const budget = 16 * 1024 * 1024;
        await backend.configureResourceBudget(budget);
        final used = (await backend.resourceStats()).residentBytes;
        await fill.createBuffer(
          BufferDescriptor(
            size: budget - used - 65536,
            usage: {BufferUsage.storage},
          ),
        );
        await draw(scene);
        var inspection = await backend.inspectGpu();
        expect(inspection.frameProfile!.passes['energyLut']?.executed, false);
        expect(hasTable(inspection), false);
        // Switching to fallback must account for its real allocation even when
        // the supplied environment frame already fit in the same budget.
        await expectLater(
          draw(scene, supplied: false),
          throwsA(isA<SceneException>()),
        );
        await draw(scene);
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .passes['energyLut']
              ?.executed,
          false,
        );
        await fill.close();
        await draw(scene, supplied: false);
        inspection = await backend.inspectGpu();
        expect(inspection.frameProfile!.passes['energyLut']?.executed, true);
        expect(hasTable(inspection), true);
        await draw(scene);
        inspection = await backend.inspectGpu();
        expect(inspection.frameProfile!.passes['energyLut']?.executed, false);
        expect(hasTable(inspection), true);
        await draw(scene, supplied: false);
        expect(
          (await backend.inspectGpu())
              .frameProfile!
              .passes['energyLut']
              ?.executed,
          false,
        );
        await draw(Scene());
        expect(hasTable(await backend.inspectGpu()), false);
        await draw(Scene(), supplied: false);
        await map.close();
        await resources.close();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await map?.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'energy lookup admission rejects a full budget and retries cleanly',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      final scene = Scene()
        ..add(
          Mesh(
            PlaneGeometry(width: 2, height: 2),
            StandardMaterial(metallic: 1, roughness: .6),
          ),
        )
        ..add(DirectionalLight());
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      Future<void> draw(Scene content) async {
        await backend.render(
          FrameSubmission.capture(
            scene: content,
            camera: camera,
            size: PhysicalSize(256, 256),
          ),
        );
      }

      const budget = 16 * 1024 * 1024;
      try {
        await backend.configureResourceBudget(budget);
        await scope.createBuffer(
          BufferDescriptor(
            size: budget - 131072 + 4,
            usage: {BufferUsage.storage},
          ),
        );
        await expectLater(draw(scene), throwsA(isA<SceneException>()));
        expect(
          (await backend.resourceStats()).residentBytes,
          lessThanOrEqualTo(budget),
        );
        await scope.close();
        final samples = <String, Object?>{
          'scope':
              'single 256x256 rough metal plane, direct light, readback path; one cold and one warm sample, not a benchmark distribution',
          'adapter': backend.capabilities.name,
        };
        for (final label in ['first', 'warm']) {
          final watch = Stopwatch()..start();
          await draw(scene);
          watch.stop();
          final profile = (await backend.inspectGpu()).frameProfile!;
          samples[label] = {
            'endToEndUs': watch.elapsedMicroseconds,
            'profile': profile.toJson(),
          };
          expect(profile.passes['energyLut']?.executed, label == 'first');
        }
        final evidence = Platform.environment['ZYREN_QUALITY_EVIDENCE'];
        if (evidence != null) {
          File(
            '$evidence/first-use-cost.json',
          ).writeAsStringSync(jsonEncode(samples));
        }
        await draw(Scene());
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
