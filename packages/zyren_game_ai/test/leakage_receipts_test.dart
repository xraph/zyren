import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'perception_test.dart' show Fixture;

Map<String, Object?> permitted(ObservationFrame frame) => {
  'actor': frame.entity.toString(),
  'episode': frame.episodeId,
  'schema': frame.schemaHash,
  'tensor': sha256.convert(frame.tensor.bytes).toString(),
  'visible': frame.visibleIds,
};

void main() {
  final receipts = <String, Object?>{};
  tearDownAll(() async {
    final path = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'cases': receipts}),
    );
  });
  void record(
    String id,
    String status,
    String recovery,
    Map<String, Object?> Function() check,
  ) {
    test('native perception receipt $id', () {
      final baseline = PhysicsWorld.nativeCounts;
      final result = check();
      expect(result['after'], result['before']);
      expect(PhysicsWorld.nativeCounts, baseline);
      receipts[id] = {
        ...result,
        'status': 'passed',
        'actualStatus': status,
        'cleanupCounters': {
          'before': baseline,
          'after': PhysicsWorld.nativeCounts,
        },
        'recovery': {'action': recovery, 'status': 'passed'},
        'execution': {
          'kind': 'native',
          'backend': 'rapier',
          'os': Platform.operatingSystem,
          'exitCode': 0,
          'command':
              'fvm dart test --concurrency=1 test/leakage_receipts_test.dart',
        },
      };
    });
  }

  record('sensor.unknown', 'unknown', 'restore_geometry_coverage', () {
    final f = Fixture();
    try {
      f.entity('target', const Vec3(0, 0, -3));
      f.world.step();
      Map<String, Object?> identity() => {
        'actor': f.actor.toString(),
        'bindings': f.bindings.keys.map((e) => e.toString()).toList(),
        'worldRevision': f.revision,
        'nativeOwners': PhysicsWorld.nativeCounts,
      };
      final before = identity();
      f.loaded = false;
      final missing = f.frame();
      expect(missing.readings.single.state, SensorState.unknown);
      expect(missing.entityMask, everyElement(0));
      expect(missing.visibleIds, isEmpty);
      final after = identity();
      f.loaded = true;
      expect(f.frame().visibleIds, ['target']);
      return {'before': before, 'after': after};
    } finally {
      f.world.close();
    }
  });

  record('leakage.hidden-position', 'withheld', 'reveal_target', () {
    Map<String, Object?> capture(double x) {
      final f = Fixture();
      try {
        f.entity('visible', const Vec3(0, 0, -2));
        f.entity('hidden', Vec3(x, 0, -8));
        final wall = f.obstacle(const Vec3(0, 0, -5), const Vec3(4, 2, .2));
        f.world.step();
        final frame = f.frame();
        expect(frame.visibleIds, ['visible']);
        final result = permitted(frame);
        wall.remove();
        f.world.step();
        expect(f.frame().visibleIds, contains('hidden'));
        return result;
      } finally {
        f.world.close();
      }
    }

    return {'before': capture(-1), 'after': capture(2)};
  });

  record(
    'leakage.hearing-uncertainty',
    'quantized',
    'resample_audible_event',
    () {
      Map<String, Object?> hear(Vec3 position, String privateId) {
        final f = Fixture();
        try {
          f.obstacle(const Vec3(0, 0, -4), const Vec3(3, 2, .1));
          f.world.step();
          final profile = SensorProfile(range: 10);
          final sensor = HearingSensor(profile, maxSounds: 1);
          final assembler = ObservationAssembler(
            registry: SensorRegistry()..register(sensor),
            profile: profile,
          );
          ObservationFrame sample(List<GameSoundEvent> sounds) =>
              assembler.build(
                SensorSnapshot.fromPhysics(
                  episodeId: 'episode',
                  tick: 2,
                  worldRevision: 1,
                  world: f.world,
                  bindings: f.bindings,
                  colliders: f.colliders,
                  currentRevision: () => 1,
                  geometryLoaded: (_, _) => true,
                  sounds: sounds.map(SensorSoundSample.fromEvent).toList(),
                ),
                f.actor,
              );
          final event = GameSoundEvent(
            id: 'cue',
            category: 'footstep',
            tick: 1,
            position: position,
            sourceEntityId: privateId,
            loudness: 1,
            range: 20,
          );
          final frame = sample([event]);
          final sound = frame.readings.single.sounds.single;
          expect(frame.visibleIds, isEmpty);
          expect(sound.obstructed, isTrue);
          expect(sound.bearingUncertaintyRadians, greaterThan(0));
          expect(
            sound.distanceUpperMetres,
            greaterThan(sound.distanceLowerMetres),
          );
          expect(sample([]).readings.single.sounds, isEmpty);
          expect(sample([event]).tensor.bytes, frame.tensor.bytes);
          return permitted(frame);
        } finally {
          f.world.close();
        }
      }

      return {
        'before': hear(const Vec3(.2, 0, -6), 'secret-a'),
        'after': hear(const Vec3(.4, 0, -6.5), 'secret-b'),
      };
    },
  );

  record('leakage.lost-sight', 'historical', 'observe_revealed_target', () {
    final f = Fixture();
    try {
      final target = f.entity('target', const Vec3(0, 0, -2));
      f.world.step();
      final memory = BeliefStore(
        identity: BrainIdentity(
          episodeId: 'episode',
          entity: f.actor,
          modelHash: 'scripted-guard',
        ),
      );
      memory.observeFrame(f.frame());
      Map<String, Object?> facts(int tick) {
        final b = memory.atTick(tick).single;
        return {
          'actor': f.actor.toString(),
          'target': b.target.toString(),
          'position': b.position!.storage,
          'observedTick': b.observedTick,
          'source': b.source.name,
        };
      }

      final before = facts(1);
      final wall = f.obstacle(const Vec3(0, 0, -4), const Vec3(3, 2, .1));
      ObservationFrame frame(int tick) => f.assembler.build(
        SensorSnapshot.fromPhysics(
          episodeId: 'episode',
          tick: tick,
          worldRevision: tick,
          world: f.world,
          bindings: f.bindings,
          colliders: f.colliders,
          currentRevision: () => tick,
          geometryLoaded: (_, _) => true,
        ),
        f.actor,
      );
      for (var tick = 2; tick <= 3; tick++) {
        target.teleport(
          PhysicsPose(position: Vec3(tick.toDouble() - 2, 0, -8)),
        );
        f.world.step();
        final hidden = frame(tick);
        expect(hidden.visibleIds, isEmpty);
        memory.observeFrame(hidden);
        expect(facts(tick), before);
        expect(memory.atTick(tick).single.ageTicks, tick - 1);
      }
      final after = facts(3);
      wall.remove();
      f.world.step();
      memory.observeFrame(frame(4));
      expect(memory.atTick(4).single.observedTick, 4);
      expect(facts(4)['position'], isNot(before['position']));
      return {'before': before, 'after': after};
    } finally {
      f.world.close();
    }
  });
}
