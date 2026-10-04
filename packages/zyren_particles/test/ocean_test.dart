import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';

void main() {
  test(
    'native suspended particles honor submersion, world motion and effective budgets',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene();
      final origin = const Vec3(6378137, 0, 0);
      final plugin = ParticlePlugin(emitters: []);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: origin + const Vec3(0, 0, 3),
          target: origin,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      final particles = OceanSuspendedParticles(plugin.controller)
        ..position = origin;
      Future<void> render(int ms) async {
        await engine.render(
          elapsed: Duration(milliseconds: ms),
          width: 32,
          height: 32,
        );
      }

      try {
        await render(0);
        final baseline = (await backend.resourceStats()).residentBytes;
        await particles.configure(
          budget: 0,
          radiusMetres: 1,
          litColor: const Color3(.1, .2, .3),
        );
        expect(plugin.controller.names, isEmpty);
        expect((await backend.resourceStats()).residentBytes, baseline);
        await particles.setSubmerged(true);
        await particles.configure(
          budget: 32,
          radiusMetres: 1,
          litColor: const Color3(.1, .2, .3),
        );
        await plugin.controller.burst(particles.name, 32);
        await render(100);
        final before = await plugin.controller.inspect(particles.name);
        expect(before.length, inInclusiveRange(1, 32));
        expect(particles.enabled, isTrue);
        final large = (await backend.resourceStats()).residentBytes;
        particles.position = origin + const Vec3(10, 0, 0);
        await render(200);
        final after = await plugin.controller.inspect(particles.name);
        expect(after.length, before.length);
        for (var i = 0; i < before.length; i++) {
          expect(
            after[i].position.distanceTo(before[i].position),
            lessThan(.1),
          );
        }
        expect(
          () => particles.configure(
            budget: 65537,
            radiusMetres: 1,
            litColor: const Color3(1, 1, 1),
          ),
          throwsArgumentError,
        );
        expect(plugin.controller.names, [particles.name]);
        await particles.configure(
          budget: 8,
          radiusMetres: 1,
          litColor: const Color3(.1, .2, .3),
        );
        await plugin.controller.burst(particles.name, 8);
        await render(300);
        expect(
          (await plugin.controller.inspect(particles.name)).length,
          inInclusiveRange(1, 8),
        );
        expect((await backend.resourceStats()).residentBytes, lessThan(large));
        expect(
          plugin.controller.measurements(particles.name).dispatches,
          greaterThan(0),
        );
        await particles.setSubmerged(false);
        await render(400);
        expect(particles.enabled, isFalse);
        expect(await plugin.controller.inspect(particles.name), isEmpty);
        await particles.configure(
          budget: 0,
          radiusMetres: 1,
          litColor: const Color3(1, 1, 1),
        );
        await render(500);
        expect(plugin.controller.names, isEmpty);
        expect(scene.children, isEmpty);
        expect((await backend.resourceStats()).residentBytes, baseline);
      } finally {
        await particles.close();
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
