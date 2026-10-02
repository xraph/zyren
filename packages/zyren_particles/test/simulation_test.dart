import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test('fixed ticks and state agree across display rates', () {
    final settings = ParticleSettings(
      capacity: 64,
      rate: 20,
      lifetime: 2,
      fixedStep: 1 / 120,
      shape: SphereParticleShape(),
      velocitySpread: Vec3.one,
    );
    List<ParticleSnapshot> run(int fps) {
      final clock = ParticleClock(settings)..start();
      final simulation = ParticleReference(settings);
      for (var f = 0; f < fps; f++) {
        for (final tick in clock.advance(1 / fps)) {
          simulation.step(tick);
        }
      }
      expect(clock.tick, 120);
      expect(clock.attempted, 20);
      return simulation.particles;
    }

    final expected = run(30);
    for (final fps in [60, 120, 144]) {
      final actual = run(fps);
      expect(actual.length, expected.length);
      for (var i = 0; i < actual.length; i++) {
        expect(actual[i].position, expected[i].position);
        expect(actual[i].velocity, expected[i].velocity);
      }
    }
  });
  test('bounded backlog, pause and reset preserve time', () {
    final settings = ParticleSettings(rate: 10, fixedStep: .01);
    final clock = ParticleClock(settings)..start();
    expect(clock.advance(1, maxSteps: 4).length, 4);
    expect(clock.pendingSeconds, closeTo(.96, 1e-9));
    clock.pause();
    expect(clock.advance(10), isEmpty);
    clock.resume();
    expect(clock.advance(0, maxSteps: 4).first.tick, 5);
    clock.reset();
    expect(clock.tick, 0);
    expect(clock.attempted, 0);
    expect(clock.playback, ParticlePlayback.stopped);
  });
  test('loop bursts are exact and stop drains without new emission', () {
    final settings = ParticleSettings(
      rate: 0,
      duration: .1,
      fixedStep: .01,
      bursts: [
        ParticleBurst(time: 0, count: 3),
        ParticleBurst(time: .05, count: 2),
      ],
    );
    final clock = ParticleClock(settings)..start();
    expect(clock.advance(.3).fold(0, (int n, t) => n + t.count), 15);
    clock.stop();
    expect(clock.advance(.1).every((t) => t.count == 0), isTrue);
    clock.reset();
    clock.start();
    expect(clock.advance(.01).single.count, 3);
  });
  test('drop and replacement are bounded and observable', () {
    for (final policy in ParticleOverflow.values) {
      final s = ParticleSettings(
        capacity: 4,
        rate: 0,
        gravity: Vec3.zero,
        overflow: policy,
      );
      final reference = ParticleReference(s);
      reference.step(ParticleTick(1, 0, 4, s.fixedStep));
      reference.step(ParticleTick(2, 4, 8, s.fixedStep));
      expect(reference.liveCount, 4);
      expect(
        reference.particles.map((p) => p.serial),
        policy == ParticleOverflow.dropNew ? [0, 1, 2, 3] : [8, 9, 10, 11],
      );
      expect(reference.dropped, policy == ParticleOverflow.dropNew ? 8 : 4);
    }
  });
  test(
    'world births use parent transform and local births retain local state',
    () {
      for (final space in ParticleSpace.values) {
        final s = ParticleSettings(
          capacity: 1,
          rate: 0,
          space: space,
          velocity: const Vec3(1, 0, 0),
          gravity: Vec3.zero,
        );
        final r = ParticleReference(s);
        r.step(
          ParticleTick(1, 0, 1, s.fixedStep),
          emitterTransform: Mat4.compose(
            const Vec3(3, 4, 5),
            Quat.identity,
            const Vec3(2, 2, 2),
          ),
        );
        expect(
          r.particles.single.position,
          space == ParticleSpace.world ? const Vec3(3, 4, 5) : Vec3.zero,
        );
        expect(
          r.particles.single.velocity,
          space == ParticleSpace.world
              ? const Vec3(2, 0, 0)
              : const Vec3(1, 0, 0),
        );
      }
    },
  );
  test('plane and box collisions project and reflect velocity', () {
    final s = ParticleSettings(
      capacity: 1,
      rate: 0,
      fixedStep: .1,
      gravity: Vec3.zero,
      shape: PointParticleShape(position: const Vec3(0, .01, 0)),
      velocity: const Vec3(0, -2, 0),
      collisions: [
        ParticlePlane(normal: const Vec3(0, 1, 0), restitution: .5),
        ...ParticleBox(
          min: const Vec3(-2, -1, -2),
          max: const Vec3(2, 2, 2),
        ).planes,
      ],
    );
    final r = ParticleReference(s)..step(const ParticleTick(1, 0, 1, .1));
    r.step(const ParticleTick(2, 1, 0, .1));
    expect(r.particles.single.position.y, closeTo(0, 1e-6));
    expect(r.particles.single.velocity.y, closeTo(1, 1e-6));
  });
  test('curves validate and interpolate exact segments', () {
    final c = ParticleCurve([CurveKey(0, 0), CurveKey(.25, 2), CurveKey(1, 0)]);
    expect(c.sample(.125), 1);
    expect(c.sample(.625), 1);
    expect(
      () => ParticleCurve([CurveKey(0, 0), CurveKey(0, 1), CurveKey(1, 2)]),
      throwsArgumentError,
    );
    expect(
      () => ParticleSettings(size: ParticleCurve.constant(-1)),
      throwsArgumentError,
    );
    expect(() => ParticleSettings(rate: double.nan), throwsArgumentError);
    expect(
      () => ParticleSettings(appearance: ParticleAppearance.mesh),
      throwsArgumentError,
    );
  });
  test('shapes respect domain and surface triangles use area', () {
    final sphere = SphereParticleShape(radius: 2, surfaceOnly: true);
    final cone = ConeParticleShape(radius: 2, height: 3);
    for (var i = 0; i < 100; i++) {
      final a = particleRandom(42, i, 0),
          b = particleRandom(42, i, 1),
          c = particleRandom(42, i, 2);
      expect(sphere.sample(a, b, c, 0).length, closeTo(2, 1e-6));
      final p = cone.sample(a, b, c, 0);
      expect(p.y, inInclusiveRange(0, 3));
      expect(
        p.x * p.x + p.z * p.z,
        lessThanOrEqualTo(4 * p.y * p.y / 9 + 1e-9),
      );
    }
  });
}
