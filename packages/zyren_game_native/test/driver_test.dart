import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support/native_game_fixture.dart';

void main() {
  test(
    'single clock produces 60 physical steps at 30, 60 and 120 rendered Hz',
    () async {
      for (final hz in [30, 60, 120]) {
        final fixture = await NativeGameFixture.create();
        try {
          await fixture.renderOneFrame(Duration.zero);
          for (var frame = 1; frame <= hz; frame++) {
            await fixture.renderOneFrame(
              Duration(microseconds: (frame * 1000000 / hz).round()),
            );
          }
          expect(fixture.physicsSteps, 60);
          expect(fixture.simulation.session.tick, 60);
          expect(fixture.body.state.pose.position.x, closeTo(1, .001));
          fixture.simulation.session.pause();
          await fixture.renderOneFrame(const Duration(seconds: 2));
          expect(fixture.physicsSteps, 60);
          fixture.simulation.session.resume();
          await fixture.renderOneFrame(const Duration(microseconds: 2016667));
          expect(fixture.physicsSteps, 61);
        } finally {
          await fixture.close();
        }
        expect(fixture.world.isClosed, isTrue);
      }
    },
  );
  test(
    'training steps share the driver and rendering cannot advance it',
    () async {
      final fixture = await NativeGameFixture.create(realtime: false);
      try {
        for (var tick = 0; tick < 60; tick++) {
          fixture.simulation.step();
        }
        final pose = fixture.body.state.pose;
        await fixture.renderOneFrame(Duration.zero);
        await fixture.renderOneFrame(const Duration(seconds: 1));
        expect(fixture.body.state.pose.position, pose.position);
        expect(fixture.body.state.pose.rotation, pose.rotation);
        expect(fixture.physicsSteps, 60);
      } finally {
        await fixture.close();
      }
    },
  );
  test(
    'headless driver rejects automatic physics, mismatched rates and duplicate owners',
    () async {
      final world = PhysicsWorld(gravity: Vec3.zero);
      final physics = PhysicsPlugin(world: world, externallyDriven: true);
      final first = GameSimulation(
        project: testProject(),
        seed: 7,
        physics: physics,
      );

      try {
        expect(
          () => GameSimulation(
            project: testProject(),
            seed: 1,
            physics: PhysicsPlugin(world: world),
          ),
          throwsArgumentError,
        );
        expect(
          () => GameSimulation(
            project: testProject(fixedHz: 30),
            seed: 1,
            physics: physics,
          ),
          throwsArgumentError,
        );
        first.step();
        expect(
          () =>
              GameSimulation(project: testProject(), seed: 8, physics: physics),
          throwsStateError,
        );
        first.step();
        expect(first.session.tick, 2);
        expect(world.isClosed, isFalse);
      } finally {
        await first.close();
        world.close();
      }
    },
  );
  test(
    'overload reports dropped time and partial attachment remains disposable',
    () async {
      final simulation = GameSimulation(
        project: testProject(),
        seed: 7,
        maxCatchUpSteps: 4,
      );
      simulation.advance(1);
      expect(simulation.session.tick, 4);
      expect(simulation.session.droppedSeconds, closeTo(56 / 60, 1e-9));
      await simulation.close();
      await simulation.close();
      expect(simulation.world.isClosed, isTrue);
    },
  );
}
