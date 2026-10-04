import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'borrowed generations enforce storage cap and retry after retirement',
    () async {
      final backend = await NativeBackend.create();
      final probes = await ReflectionProbes.create(backend);
      final borrowers = backend.createResourceScope();
      final scene = Scene()..background = const Color3(.2, .3, .4);
      final descriptor = ReflectionProbeDescriptor(
        id: 0,
        position: Vec3.zero,
        bounds: Bounds3(-Vec3.one, Vec3.one),
        faceSize: 256,
        quality: const EnvironmentQuality(
          specularWidth: 512,
          diffuseWidth: 256,
          brdfSize: 512,
          samples: 64,
        ),
      );
      var updates = 0;
      try {
        for (var revision = 1; revision <= 20; revision++) {
          try {
            await probes.update(
              descriptor,
              scene: scene,
              contentRevision: revision,
            );
          } on StateError catch (error) {
            expect(error.toString(), contains('33,554,432'));
            break;
          }
          while (probes.pending) {
            await probes.advance();
          }
          updates++;
          final map = probes.environment(0)!.map;
          await borrowers.retain(map.diffuse);
          await borrowers.retain(map.specular);
          expect(
            probes.storageBytes,
            lessThanOrEqualTo(ReflectionProbes.maxStorageBytes),
          );
        }
        expect(updates, inInclusiveRange(2, 19));
        expect(probes.revision(0), updates);
        expect(probes.pending, isFalse);
        final pressureBytes = probes.storageBytes;
        await borrowers.close();
        await probes.reclaim();
        expect(probes.retainedGenerations, 0);
        expect(probes.storageBytes, lessThan(pressureBytes));
        await probes.update(descriptor, scene: scene, contentRevision: 100);
        while (probes.pending) {
          await probes.advance();
        }
        expect(probes.revision(0), 100);
        print(
          'probe pressure: $updates generations before admission rejection; $pressureBytes logical bytes retained; retry ${probes.storageBytes} bytes',
        );
      } finally {
        await borrowers.close();
        await probes.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
