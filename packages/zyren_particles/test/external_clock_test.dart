import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test(
    'external ticks carry birth velocity and rendering never advances them',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene();
      final plugin = ParticlePlugin(
        emitters: [
          ParticleEmitter(
            name: 'fixed',
            externallyDriven: true,
            settings: ParticleSettings(
              capacity: 8,
              fixedStep: 1 / 60,
              rate: 0,
              lifetime: 5,
              gravity: Vec3.zero,
              drag: 0,
              space: ParticleSpace.world,
              velocity: const Vec3(0, 1, 0),
              velocitySpread: Vec3.zero,
            ),
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(0, 0, 5),
          target: Vec3.zero,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      final control = plugin.controller;
      try {
        await control.burst('fixed', 1);
        await control.step(
          'fixed',
          tick: 1,
          emissionVelocity: const Vec3(2, 0, 0),
        );
        final birth = (await control.inspect('fixed')).single;
        expect(birth.velocity.distanceTo(const Vec3(2, 1, 0)), lessThan(1e-6));
        for (var i = 0; i < 10; i++) {
          await engine.render(
            elapsed: Duration(milliseconds: i * 50),
            width: 24,
            height: 24,
          );
        }
        expect(control.simulationTick('fixed'), 1);
        expect(
          (await control.inspect('fixed')).single.position,
          birth.position,
        );
        await control.step('fixed', tick: 2);
        final moved = (await control.inspect('fixed')).single;
        expect(
          moved.position.distanceTo(birth.position + birth.velocity / 60),
          lessThan(1e-6),
        );
        await expectLater(control.step('fixed', tick: 2), throwsStateError);
        await expectLater(control.step('fixed', tick: 4), throwsStateError);
        expect(control.simulationTick('fixed'), 2);
      } finally {
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
