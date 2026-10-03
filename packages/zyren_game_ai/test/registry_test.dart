import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

class CustomSensor implements GameSensor {
  @override
  final String id;
  @override
  final int queryBudget;
  final void Function()? mutate;
  var width = 1;
  CustomSensor(this.id, {this.queryBudget = 0, this.mutate});
  @override
  int get cadenceTicks => 1;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    fields: [ObservationField('value', width: width)],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    mutate?.call();
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: SensorState.known,
      provenance: SensorProvenance.custom,
      values: List.filled(width, .5),
      validity: List.filled(width, 1),
    );
  }
}

void main() {
  test(
    'a revision change during a later sensor invalidates the whole frame',
    () {
      var revision = 1;
      final actor = GameEntityHandle('actor', 1);
      final registry = SensorRegistry()
        ..register(CustomSensor('first'))
        ..register(CustomSensor('second', mutate: () => revision++));
      final assembler = ObservationAssembler(
        registry: registry,
        profile: SensorProfile(),
      );
      final snapshot = SensorSnapshot(
        episodeId: 'ep',
        tick: 1,
        worldRevision: 1,
        entities: [SensorEntity(handle: actor, pose: PhysicsPose())],
        colliders: {},
        currentRevision: () => revision,
        geometryLoaded: (_, _) => true,
      );
      final frame = assembler.build(snapshot, actor);
      expect(frame.tensor.float32Values, everyElement(0));
      expect(
        frame.readings.map((r) => r.state),
        everyElement(SensorState.unknown),
      );
    },
  );
  test(
    'changed custom schema and unregistered sensors cannot reuse an old pin',
    () {
      final actor = GameEntityHandle('actor', 1);
      final snapshot = SensorSnapshot(
        episodeId: 'ep',
        tick: 1,
        worldRevision: 1,
        entities: [SensorEntity(handle: actor, pose: PhysicsPose())],
        colliders: {},
        currentRevision: () => 1,
        geometryLoaded: (_, _) => true,
      );
      final sensor = CustomSensor('custom');
      final registry = SensorRegistry()..register(sensor);
      sensor.width = 2;
      expect(() => registry.sample(sensor, snapshot, actor), throwsStateError);
      sensor.width = 1;
      registry.unregister(sensor.id);
      expect(() => registry.sample(sensor, snapshot, actor), throwsStateError);
    },
  );
  test(
    'aggregate declared native query budgets cannot exceed the registry cap',
    () {
      final registry = SensorRegistry()
        ..register(CustomSensor('full', queryBudget: 4096));
      expect(
        () => registry.register(CustomSensor('extra', queryBudget: 1)),
        throwsStateError,
      );
    },
  );
}
