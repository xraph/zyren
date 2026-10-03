import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'channel bounds expiry range membership and event replay without unknown targets',
    () {
      final h = TeamHarness(
        CommunicationProfile(
          delayTicks: 1,
          ttlTicks: 4,
          maxPending: 1,
          maxEventIds: 1,
        ),
      );
      h.capture();
      expect(h.send('once'), true);
      expect(h.send('capacity'), false);
      expect(h.channel.receive(h.b, tick: 4), hasLength(1));
      h.tick = 4;
      h.capture();
      expect(h.send('once'), false);
      expect(h.send('ledger-full'), false);
      final expired = TeamHarness(
        CommunicationProfile(delayTicks: 1, ttlTicks: 4),
      );
      expired.capture();
      expect(expired.send('expire'), true);
      expect(expired.channel.receive(expired.b, tick: 7), isEmpty);
      final historical = TeamHarness(CommunicationProfile(delayTicks: 1));
      historical.capture();
      historical.entities.despawn(historical.target);
      expect(historical.send('historical-target'), true);
      expect(
        historical.channel.receive(historical.b, tick: 4).single.target,
        historical.target,
      );
      final changed = TeamHarness(CommunicationProfile(delayTicks: 1));
      changed.capture();
      expect(changed.send('team-change'), true);
      changed.team.leave(changed.b);
      changed.enemies.join(changed.identity(changed.b));
      expect(changed.channel.receive(changed.b, tick: 4), isEmpty);
      final removed = TeamHarness(CommunicationProfile(delayTicks: 1));
      removed.capture();
      expect(removed.send('sender-remove'), true);
      removed.entities.despawn(removed.a);
      expect(removed.channel.receive(removed.b, tick: 4), isEmpty);
      final range = TeamHarness(CommunicationProfile(range: 2));
      range.recipientPosition = const Vec3(10, 0, 0);
      range.capture();
      expect(range.send('range'), false);
      range.recipientPosition = const Vec3(1, 0, 0);
      range.capture();
      range.revision++;
      expect(range.send('stale-world'), false);
      expect(
        () => TeamChannel(
          teams: [range.team, range.team],
          profile: range.channel.profile,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'team membership pins episode and live generations with bounded changes',
    () {
      final entities = GameEntityTable();
      final a = entities.spawn('a'), b = entities.spawn('b');
      final team = GameTeam(
        id: 'allies',
        episodeId: 'e',
        entities: entities,
        maxMembers: 1,
      );
      final identity = BrainIdentity(
        episodeId: 'e',
        entity: a,
        modelHash: 'probe',
      );
      team.join(identity);
      expect(team.members, [identity]);
      expect(
        () => team.join(
          BrainIdentity(episodeId: 'e', entity: b, modelHash: 'probe'),
        ),
        throwsStateError,
      );
      expect(
        () => team.join(
          BrainIdentity(episodeId: 'other', entity: a, modelHash: 'probe'),
        ),
        throwsArgumentError,
      );
      final epoch = team.membershipEpoch(a);
      team.leave(a);
      team.join(identity);
      expect(team.membershipEpoch(a), greaterThan(epoch));
      entities.despawn(a);
      expect(team.contains(a), false);
    },
  );
  test(
    'messages derive only visible provenance and reserve recipient membership',
    () {
      final entities = GameEntityTable();
      final sender = entities.spawn('a'),
          recipient = entities.spawn('b'),
          target = entities.spawn('t');
      BrainIdentity identity(GameEntityHandle h) =>
          BrainIdentity(episodeId: 'e', entity: h, modelHash: 'probe');
      final team = GameTeam(id: 'allies', episodeId: 'e', entities: entities)
        ..join(identity(sender))
        ..join(identity(recipient));
      final channel = TeamChannel(
        teams: [team],
        profile: CommunicationProfile(delayTicks: 2, ttlTicks: 8, range: 10),
      );
      final sensor = TeamFixtureSensor(target);
      final registry = SensorRegistry()..register(sensor);
      final assembler = ObservationAssembler(
        registry: registry,
        profile: SensorProfile(maxEntities: 2),
      );
      SensorSnapshot snapshot(GameEntityHandle observer) => SensorSnapshot(
        episodeId: 'e',
        tick: 3,
        worldRevision: 0,
        entities: [SensorEntity(handle: observer, pose: PhysicsPose())],
        colliders: {},
        currentRevision: () => 0,
        geometryLoaded: (_, _) => true,
      );
      ObservationFrame frame(GameEntityHandle observer, {bool visible = true}) {
        sensor.visible = visible;
        return assembler.build(snapshot(observer), observer);
      }

      channel.capture(
        SensorSnapshot(
          episodeId: 'e',
          tick: 3,
          worldRevision: 0,
          entities: [
            SensorEntity(handle: sender, pose: PhysicsPose()),
            SensorEntity(
              handle: recipient,
              pose: PhysicsPose(position: const Vec3(1, 0, 0)),
            ),
          ],
          colliders: {},
          currentRevision: () => 0,
          geometryLoaded: (_, _) => true,
        ),
      );
      channel.observe(frame(sender));
      expect(
        channel.send(
          id: 'event',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        true,
      );
      expect(
        channel.send(
          id: 'event',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        false,
      );
      expect(channel.receive(recipient, tick: 4), isEmpty);
      final delivered = channel.receive(recipient, tick: 5).single;
      expect(delivered.observedTick, 3);
      expect(delivered.position, const Vec3(2, 0, 0));
      expect(delivered.provenance, SensorProvenance.visible);
      expect(channel.receive(recipient, tick: 5), isEmpty);
      channel.observe(frame(sender, visible: false));
      expect(
        channel.send(
          id: 'spoofed-target',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        false,
      );
      final invalidation = TeamChannel(teams: [team], profile: channel.profile);
      invalidation.capture(
        SensorSnapshot(
          episodeId: 'e',
          tick: 3,
          worldRevision: 0,
          entities: [
            SensorEntity(handle: sender, pose: PhysicsPose()),
            SensorEntity(
              handle: recipient,
              pose: PhysicsPose(position: const Vec3(1, 0, 0)),
            ),
          ],
          colliders: {},
          currentRevision: () => 0,
          geometryLoaded: (_, _) => true,
        ),
      );
      invalidation.observe(frame(sender));
      expect(
        invalidation.send(
          id: 'leave',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        true,
      );
      team.leave(sender);
      team.join(identity(sender));
      expect(
        invalidation.send(
          id: 'old-frame',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        false,
      );
      invalidation.observe(frame(sender));
      expect(
        invalidation.send(
          id: 'remove',
          sender: sender,
          recipient: recipient,
          target: target,
          tick: 3,
        ),
        true,
      );
      entities.despawn(sender);
      expect(invalidation.receive(recipient, tick: 5), isEmpty);
    },
  );
}

class TeamFixtureSensor implements GameSensor {
  final GameEntityHandle target;
  bool visible = true;
  TeamFixtureSensor(this.target);
  @override
  String get id => 'vision';
  @override
  int get queryBudget => 0;
  @override
  int get cadenceTicks => 1;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    fields: [ObservationField('seen', min: 0, max: 1)],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) =>
      SensorReading(
        sensorId: id,
        tick: snapshot.tick,
        state: SensorState.known,
        provenance: SensorProvenance.visible,
        values: [1],
        validity: [1],
        entities: visible
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

class TeamHarness {
  final entities = GameEntityTable();
  late final a = entities.spawn('a'),
      b = entities.spawn('b'),
      target = entities.spawn('target');
  late final team = GameTeam(id: 'allies', episodeId: 'e', entities: entities)
    ..join(identity(a))
    ..join(identity(b));
  late final enemies = GameTeam(
    id: 'enemies',
    episodeId: 'e',
    entities: entities,
  );
  late final TeamChannel channel;
  late final sensor = TeamFixtureSensor(target);
  late final assembler = ObservationAssembler(
    registry: SensorRegistry()..register(sensor),
    profile: SensorProfile(),
  );
  int tick = 3, revision = 0;
  Vec3 recipientPosition = const Vec3(1, 0, 0);
  TeamHarness(CommunicationProfile profile) {
    channel = TeamChannel(teams: [team, enemies], profile: profile);
  }
  BrainIdentity identity(GameEntityHandle actor) =>
      BrainIdentity(episodeId: 'e', entity: actor, modelHash: 'probe');
  void capture() {
    final snapshot = SensorSnapshot(
      episodeId: 'e',
      tick: tick,
      worldRevision: revision,
      entities: [
        SensorEntity(handle: a, pose: PhysicsPose()),
        SensorEntity(
          handle: b,
          pose: PhysicsPose(position: recipientPosition),
        ),
      ],
      colliders: {},
      currentRevision: () => revision,
      geometryLoaded: (_, _) => true,
    );
    channel.capture(snapshot);
    channel.observe(assembler.build(snapshot, a));
  }

  bool send(String id) =>
      channel.send(id: id, sender: a, recipient: b, target: target, tick: tick);
}
