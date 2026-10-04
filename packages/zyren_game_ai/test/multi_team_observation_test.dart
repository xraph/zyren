import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

class TeamSensorStub implements GameSensor {
  final GameSensor original;
  final GameEntityHandle target;
  TeamSensorStub(this.original, this.target);
  @override
  String get id => original.id;
  @override
  int get cadenceTicks => original.cadenceTicks;
  @override
  int get queryBudget => original.queryBudget;
  @override
  ObservationSpec get schema => original.schema;
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) =>
      SensorReading(
        sensorId: id,
        tick: snapshot.tick,
        state: SensorState.known,
        provenance: id == 'vision'
            ? SensorProvenance.visible
            : SensorProvenance.body,
        values: List.filled(schema.width, 0.0),
        validity: List.filled(schema.width, 1),
        entities: id == 'vision'
            ? [
                ObservedEntity(
                  target,
                  const Vec3(2, 0, 0),
                  snapshot.tick,
                  SensorProvenance.visible,
                ),
              ]
            : [],
      );
}

final class MultiFrameHarness {
  final entities = GameEntityTable();
  late final a = entities.spawn('a'),
      b = entities.spawn('b'),
      target = entities.spawn('target');
  late final profile = TrainingMultiProfiles.forTask(
    task: 'cooperative-search',
  );
  late final team = GameTeam(id: 'search', episodeId: 'e', entities: entities)
    ..join(identity(a))
    ..join(identity(b));
  late final channel = TeamChannel(
    teams: [team],
    profile: profile.communication,
  );
  SensorRegistry registry() {
    final result = SensorRegistry();
    for (final sensor in profile.assembler.registry.sensors) {
      result.register(TeamSensorStub(sensor, target));
    }
    return result;
  }

  late final assembler = ObservationAssembler(
    registry: registry(),
    profile: profile.perception,
  );
  BrainIdentity identity(GameEntityHandle handle) => BrainIdentity(
    episodeId: 'e',
    entity: handle,
    modelHash: 'scripted-guard',
  );
  ObservationFrame frame(GameEntityHandle handle, int tick, PhysicsPose pose) {
    return assembler.build(
      SensorSnapshot(
        episodeId: 'e',
        tick: tick,
        worldRevision: tick,
        entities: [SensorEntity(handle: handle, pose: pose)],
        colliders: {},
        currentRevision: () => tick,
        geometryLoaded: (_, _) => true,
      ),
      handle,
    );
  }

  TeamMessage message() {
    channel.capture(
      SensorSnapshot(
        episodeId: 'e',
        tick: 5,
        worldRevision: 5,
        entities: [
          SensorEntity(
            handle: a,
            pose: PhysicsPose(position: const Vec3(10, 0, 0)),
          ),
          SensorEntity(
            handle: b,
            pose: PhysicsPose(position: const Vec3(11, 0, 0)),
          ),
        ],
        colliders: {},
        currentRevision: () => 5,
        geometryLoaded: (_, _) => true,
      ),
    );
    channel.observe(frame(a, 5, PhysicsPose(position: const Vec3(10, 0, 0))));
    expect(
      channel.send(
        id: 'visible-goal',
        sender: a,
        recipient: b,
        target: target,
        tick: 5,
      ),
      true,
    );
    expect(channel.receive(b, tick: 6), isEmpty);
    return channel.receive(b, tick: 7).single;
  }
}

void main() {
  test(
    'team augmentation uses captured sender pose and exact historical validity',
    () {
      final h = MultiFrameHarness();
      final adapter = GameMultiObservationAdapter(
        identity: h.identity(h.b),
        profile: h.profile,
        role: 'searcher',
        goal: h.target,
        authoredRoute: [const Vec3(5, 0, 0)],
      );
      final message = h.message();
      expect(
        adapter.accept(
          message,
          senderPoseTick: 5,
          senderPose: PhysicsPose(position: const Vec3(10, 0, 0)),
          tick: 7,
        ),
        true,
      );
      final frame = adapter.compose(
        h.frame(h.b, 7, PhysicsPose(position: const Vec3(1, 0, 0))),
        observerPose: PhysicsPose(position: const Vec3(1, 0, 0)),
      );
      final extra = frame.tensor.float32Values
          .skip(h.profile.assembler.spec.width)
          .toList();
      expect(frame.schemaHash, h.profile.spec.hash);
      expect(frame.tensor.shape, [1, h.profile.spec.width]);
      expect(extra, [
        -1,
        closeTo(4 / 15, 1e-7),
        0,
        1,
        closeTo(11 / 15, 1e-7),
        0,
        0,
        closeTo(.02, 1e-7),
        1,
        1,
      ]);
      expect(frame.visibleIds, h.frame(h.b, 7, PhysicsPose()).visibleIds);
      final expired = adapter.compose(
        h.frame(h.b, 105, PhysicsPose()),
        observerPose: PhysicsPose(),
      );
      expect(
        expired.tensor.float32Values.skip(h.profile.assembler.spec.width + 4),
        List.filled(6, 0),
      );
      expect(
        () => adapter.compose(expired, observerPose: PhysicsPose()),
        throwsArgumentError,
      );
    },
  );
  test(
    'wrong frame, recipient, goal, timestamp and competitive messages fail closed',
    () {
      final h = MultiFrameHarness(), message = h.message();
      final adapter = GameMultiObservationAdapter(
        identity: h.identity(h.b),
        profile: h.profile,
        role: 'searcher',
        goal: h.target,
      );
      expect(
        () => adapter.accept(
          message,
          senderPoseTick: 6,
          senderPose: PhysicsPose(),
          tick: 7,
        ),
        throwsArgumentError,
      );
      final sender = GameMultiObservationAdapter(
        identity: h.identity(h.a),
        profile: h.profile,
        role: 'scout',
        goal: h.target,
      );
      expect(
        sender.accept(
          message,
          senderPoseTick: 5,
          senderPose: PhysicsPose(),
          tick: 7,
        ),
        false,
      );
      final competitive = GameMultiObservationAdapter(
        identity: h.identity(h.b),
        profile: TrainingMultiProfiles.forTask(task: 'competitive-pursuit'),
        role: 'evader',
      );
      expect(
        competitive.accept(
          message,
          senderPoseTick: 5,
          senderPose: PhysicsPose(),
          tick: 7,
        ),
        false,
      );
      expect(
        () => adapter.compose(
          h.frame(h.a, 7, PhysicsPose()),
          observerPose: PhysicsPose(),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'route progress and saved history restore only through fresh handle remap',
    () {
      final h = MultiFrameHarness();
      final adapter = GameMultiObservationAdapter(
        identity: h.identity(h.b),
        profile: h.profile,
        role: 'searcher',
        goal: h.target,
        authoredRoute: [Vec3.zero, const Vec3(2, 0, 0)],
      );
      adapter.accept(
        h.message(),
        senderPoseTick: 5,
        senderPose: PhysicsPose(position: const Vec3(10, 0, 0)),
        tick: 7,
      );
      adapter.compose(
        h.frame(h.b, 7, PhysicsPose()),
        observerPose: PhysicsPose(),
      );
      expect(adapter.routeIndex, 1);
      final saved = adapter.snapshot(tick: 7);
      final fresh = GameEntityHandle('b', h.b.generation + 1),
          newTarget = GameEntityHandle('target', h.target.generation + 1);
      final restored = GameMultiObservationAdapter(
        identity: BrainIdentity(
          episodeId: 'fresh',
          entity: fresh,
          modelHash: 'scripted-guard',
        ),
        profile: h.profile,
        role: 'searcher',
        goal: newTarget,
        authoredRoute: [Vec3.zero, const Vec3(2, 0, 0)],
      );
      restored.restore(
        saved,
        tick: 7,
        remap: (old) => old == h.b
            ? fresh
            : old == h.target
            ? newTarget
            : old == h.a
            ? h.a
            : null,
      );
      expect(restored.routeIndex, 1);
      final incompatible = {...saved, 'routeHash': 'f' * 64};
      expect(
        () => restored.restore(incompatible, tick: 7, remap: (old) => old),
        throwsFormatException,
      );
      restored.reset();
      expect(restored.routeIndex, 0);
    },
  );
}
