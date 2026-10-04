import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
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
