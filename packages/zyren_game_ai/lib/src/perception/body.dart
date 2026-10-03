part of '../../zyren_game_ai.dart';

final class BodySensor implements GameSensor {
  final double maxSpeed;
  @override
  final int cadenceTicks;
  BodySensor({this.maxSpeed = 100, this.cadenceTicks = 1}) {
    if (!maxSpeed.isFinite || maxSpeed <= 0) {
      throw ArgumentError('Invalid speed bound.');
    }
  }
  @override
  String get id => 'body';
  @override
  int get queryBudget => 0;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    cadenceTicks: cadenceTicks,
    fields: [
      ObservationField(
        'localVelocity',
        units: 'metres/second',
        width: 3,
        min: -maxSpeed,
        max: maxSpeed,
        scale: maxSpeed,
      ),
      ObservationField('grounded', min: 0, max: 1),
    ],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final actor = snapshot.entities[entity];
    if (actor == null) {
      return _empty(
        this,
        snapshot.tick,
        SensorState.unknown,
        'entity-missing',
        provenance: SensorProvenance.body,
      );
    }
    final velocity = _local(actor.pose.rotation, actor.velocity);
    final speedKnown = velocity.storage.every((v) => v.abs() <= maxSpeed);
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: speedKnown && actor.grounded != null
          ? SensorState.known
          : SensorState.unknown,
      provenance: SensorProvenance.body,
      values: [
        ...speedKnown ? velocity.storage : [0.0, 0.0, 0.0],
        actor.grounded == true ? 1 : 0,
      ],
      validity: [
        ...List.filled(3, speedKnown ? 1 : 0),
        actor.grounded == null ? 0 : 1,
      ],
    );
  }
}
