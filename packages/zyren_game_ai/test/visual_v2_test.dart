import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';

VisualNavigationMap publishedMap({
  bool strip = false,
  double radius = .3,
  double height = 1.8,
}) {
  final geometry = NavigationGeometry(
    sourceId: 'published-floor',
    revision: '1',
    vertices: const [
      Vec3(-6, 0, -6),
      Vec3(6, 0, -6),
      Vec3(6, 0, 6),
      Vec3(-6, 0, 6),
    ],
    triangles: const [
      [0, 2, 1],
      [0, 3, 2],
    ],
  );
  final noEntry = [
    if (strip)
      VisualNoEntryPolygon(
        sourceId: 'published-strip',
        vertices: const [
          Vec3(-1, 0, 2),
          Vec3(1, 0, 2),
          Vec3(1, 0, 2.4),
          Vec3(-1, 0, 2.4),
        ],
      ),
  ];
  final settings = NavigationBakeSettings(
    cellSize: .2,
    radius: radius,
    height: height,
    maxCells: 16384,
  );
  return VisualNavigationMap.fromAuthored(
    expectedHash: VisualNavigationMap.contentHash(
      walkable: [geometry],
      noEntry: noEntry,
      settings: settings,
    ),
    walkable: [geometry],
    noEntry: noEntry,
    settings: settings,
  );
}

final profile = VisualNavigationProfile(family: 'guard', mode: 'combined');
VisualCaptureIdentity identity(
  VisualNavigationMap map, {
  int stateEpoch = 0,
  String family = 'guard',
}) => VisualCaptureIdentity(
  episodeId: 'episode',
  actor: GameEntityHandle('actor', 1),
  profileHash: VisualNavigationProfile(family: family, mode: 'combined').hash,
  modelHash: '1' * 64,
  mapHash: map.hash,
  gameEpoch: 0,
  controlEpoch: 0,
  stateEpoch: stateEpoch,
  cameraRevision: 0,
  mapRevision: 0,
);
VisualCapturePose pose(
  VisualCaptureIdentity id, {
  int tick = 0,
  Vec3 position = const Vec3(.1, .81, .1),
  double yaw = 0,
}) => VisualCapturePose(
  identity: id,
  profile: profile,
  actorPose: PhysicsPose(position: position),
  groundY: 0,
  cameraYaw: yaw,
  captureTick: tick,
  worldRevision: tick,
);
List<double> visible({
  double forward = 4,
  double sigma = 0,
  double free = 40,
}) => [...VisualEstimate.spec.fallbackContinuous]
  ..setRange(0, 8, [0, forward, 0, 0, sigma, 0, 1, 1])
  ..setRange(56, 74, [
    for (var i = 0; i < 9; i++) ...[1, free],
  ]);
VisualMotionDecision decide(
  VisualGoalController controller,
  int tick, {
  Vec3 position = const Vec3(.1, .81, .1),
  Vec3 velocity = Vec3.zero,
}) => controller.decide(
  tick: tick,
  ownPose: PhysicsPose(position: position),
  ownVelocity: velocity,
  groundY: 0,
);

void main() {
  test(
    'actual collider and bake clearance must match the pinned model footprint',
    () {
      for (final shape in [
        const CapsuleShape(halfHeight: .5, radius: .2),
        const CapsuleShape(halfHeight: .5, radius: .4),
        const CapsuleShape(halfHeight: .4, radius: .3),
        const BoxShape(Vec3(.3, .8, .3)),
      ]) {
        final map = publishedMap();
        expect(
          () => VisualGoalController(
            profile: profile,
            map: map,
            identity: identity(map),
            actorShape: shape,
            actorOffset: PhysicsPose(),
          ),
          throwsArgumentError,
        );
      }
      for (final map in [
        publishedMap(radius: .29),
        publishedMap(height: 1.59),
      ]) {
        expect(
          () => VisualGoalController(
            profile: profile,
            map: map,
            identity: identity(map),
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
          ),
          throwsArgumentError,
        );
      }
      final map = publishedMap();
      expect(
        () => VisualGoalController(
          profile: profile,
          map: map,
          identity: identity(map),
          actorShape: profile.actorShape,
          actorOffset: PhysicsPose(position: const Vec3(.1, 0, 0)),
        ),
        throwsArgumentError,
      );
      final controller = VisualGoalController(
        profile: profile,
        map: map,
        identity: identity(map),
        actorShape: profile.actorShape,
        actorOffset: PhysicsPose(),
      );
      expect(controller.toJson()['actorShape'], profile.actorShape.json);
      expect(profile.toJson()['footprint_radius'], .3);
      final car = VisualNavigationProfile(family: 'vehicle', mode: 'combined');
      expect(
        car.footprintRadius,
        closeTo(math.sqrt(.8 * .8 + 1.2 * 1.2), 1e-12),
      );
      expect(
        () => VisualGoalController(
          profile: car,
          map: map,
          identity: identity(map, family: 'vehicle'),
          actorShape: car.actorShape,
          actorOffset: PhysicsPose(),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'all six profile contracts preserve camera-only/body10 and distinct controller ABI',
    () {
      for (final family in ['guard', 'vehicle']) {
        for (final mode in ['rgb', 'depth', 'combined']) {
          final p = VisualNavigationProfile(family: family, mode: mode);
          expect(
            p.width,
            {'rgb': 21178, 'depth': 14122, 'combined': 35290}[mode],
          );
          expect(p.spec.cadenceTicks, 5);
          expect(p.spec.latencyTicks, 2);
          expect(p.spec.width, p.width);
          expect(p.spec.configurationHash, p.hash);
          expect(p.toJson().containsKey('target'), false);
          expect(
            p.controllerDecoder.spec.hash,
            isNot(VisualEstimate.spec.hash),
          );
        }
      }
    },
  );
  test(
    'camera composition snapshots native depth planes and captured heading/mount',
    () {
      final body = profile.ownBody(
        pose: PhysicsPose(
          position: const Vec3(0, 1, 0),
          rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
        ),
        velocity: const Vec3(2, 0, 0),
        angularVelocity: Vec3.zero,
        cameraYaw: -math.pi / 2,
      );
      final values = Float32List(35280);
      values[4 * 7056] = 1;
      values[3 * 7056] = .5;
      final tensor = profile.compose(
        MlTensor.float32([1, 5, 84, 84], values),
        ownBody: body,
      );
      expect(tensor.shape, [1, 35290]);
      expect(body[2], closeTo(2, 1e-9));
      expect(body[5], closeTo(1, 1e-9));
      expect(body[7], closeTo(-1, 1e-9));
      values[3 * 7056] = 0;
      expect(tensor.float32Values[3 * 7056], .5);
      expect(
        () => profile.compose(
          MlTensor.float32([1, 5, 84, 84], Float32List(35280)),
          ownBody: [...body]..[9] = 0,
        ),
        throwsArgumentError,
      );
      final invalid = Float32List(35280)..[3 * 7056] = .2;
      expect(
        () => profile.compose(
          MlTensor.float32([1, 5, 84, 84], invalid),
          ownBody: body,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    '74 estimate values reject shape, NaN, bounds and claimed offscreen geometry',
    () {
      for (final values in [
        [...visible(), 0.0],
        [...visible()]..[0] = double.nan,
        [...visible()]..[56] = 1.1,
        [...visible()]..[0] = 30,
      ]) {
        expect(
          () => VisualEstimate.decode(values, profile: profile),
          throwsArgumentError,
        );
      }
      final values = visible();
      final estimate = VisualEstimate.decode(values, profile: profile);
      values[1] = 1;
      expect(estimate.target.forward, 4);
      expect(() => estimate.values.clear(), throwsUnsupportedError);
      expect(() => estimate.obstacles.clear(), throwsUnsupportedError);
      expect(VisualEstimate.unknown(profile).target.admitted, false);
    },
  );
  test(
    'authored map requires byte pin and explicit bounded source allowlist',
    () {
      final map = publishedMap(strip: true);
      expect(map.noEntry.single.sourceId, 'published-strip');
      expect(() => map.noEntry.clear(), throwsUnsupportedError);
      expect(
        () => VisualNavigationMap.fromAuthored(
          expectedHash: '0' * 64,
          walkable: map.walkable,
          noEntry: map.noEntry,
          settings: map.mesh.settings,
        ),
        throwsArgumentError,
      );
      expect(
        () => VisualNavigationMap.fromAuthored(
          expectedHash: map.hash,
          walkable: map.walkable,
          noEntry: map.noEntry,
          settings: NavigationBakeSettings(maxCells: 16385),
        ),
        throwsArgumentError,
      );
      expect(
        () => VisualNoEntryPolygon(
          sourceId: 'bad',
          vertices: const [Vec3.zero, Vec3(1, 0, 0), Vec3(2, 0, 0)],
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'capture transform uses copied pose and camera yaw, never later actor pose',
    () {
      final map = publishedMap(), id = identity(publishedMap());
      final c = VisualGoalController(
        actorShape: profile.actorShape,
        actorOffset: PhysicsPose(),
        profile: profile,
        map: map,
        identity: id,
      );
      final captured = pose(id, yaw: math.pi / 2);
      c.accept(
        estimate: VisualEstimate.decode(visible(), profile: profile),
        captured: captured,
        tick: 2,
      );
      final measured = c.belief!.position;
      expect(measured.x, closeTo(4.1, 1e-9));
      expect(measured.z, closeTo(.45, 1e-9));
      decide(c, 3, position: const Vec3(-2, .81, -2));
      expect(c.belief!.position, measured);
    },
  );
  test(
    'exact due tick/epoch/profile pins reject late and duplicate completion',
    () {
      final map = publishedMap(), id = identity(publishedMap());
      final c = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: map,
            identity: id,
          ),
          est = VisualEstimate.decode(visible(), profile: profile);
      expect(c.accept(estimate: est, captured: pose(id), tick: 1), false);
      expect(c.accept(estimate: est, captured: pose(id), tick: 3), false);
      expect(
        c.accept(
          estimate: est,
          captured: pose(identity(map, stateEpoch: 1)),
          tick: 2,
        ),
        false,
      );
      expect(c.accept(estimate: est, captured: pose(id), tick: 2), true);
      expect(c.accept(estimate: est, captured: pose(id), tick: 2), false);
      final p = VisualNavigationProfile(family: 'guard', mode: 'depth');
      expect(
        c.accept(
          estimate: VisualEstimate.decode(visible(forward: 2.5), profile: p),
          captured: pose(id, tick: 5),
          tick: 7,
        ),
        false,
      );
    },
  );
  test(
    'invisible estimate cannot refresh retained goal; TTL and growing uncertainty stop',
    () {
      final map = publishedMap(),
          id = identity(publishedMap()),
          c = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: publishedMap(),
            identity: identity(publishedMap()),
          );
      c.accept(
        estimate: VisualEstimate.decode(visible(), profile: profile),
        captured: pose(id),
        tick: 2,
      );
      c.accept(
        estimate: VisualEstimate.unknown(profile),
        captured: pose(id, tick: 5),
        tick: 7,
      );
      expect(c.belief!.captured.captureTick, 0);
      expect(c.belief!.goalAt(id, 600), isNotNull);
      expect(c.belief!.goalAt(id, 601), isNull);
      c.reset(identity(map, stateEpoch: 1));
      expect(c.belief, isNull);
      final sigma = VisualGoalController(
        actorShape: profile.actorShape,
        actorOffset: PhysicsPose(),
        profile: profile,
        map: map,
        identity: id,
      );
      sigma.accept(
        estimate: VisualEstimate.decode(visible(sigma: .749), profile: profile),
        captured: pose(id),
        tick: 2,
      );
      expect(decide(sigma, 2).state, VisualMotionState.unknownGoal);
    },
  );
  test(
    'known stopping corridor grants typed motion, unknown/short/stale space stops',
    () {
      final map = publishedMap(), id = identity(publishedMap());
      for (final free in [0.0, 1.0, 40.0]) {
        final c = VisualGoalController(
          actorShape: profile.actorShape,
          actorOffset: PhysicsPose(),
          profile: profile,
          map: map,
          identity: id,
        );
        c.accept(
          estimate: VisualEstimate.decode(
            visible(free: free),
            profile: profile,
          ),
          captured: pose(id),
          tick: 2,
        );
        final action = decide(c, 2);
        expect(
          action.state,
          free == 40
              ? VisualMotionState.moving
              : VisualMotionState.unknownClearance,
        );
        if (free == 40) {
          expect(action.character!.moveZ, greaterThan(0));
          expect(decide(c, 26).state, VisualMotionState.unknownClearance);
        } else {
          expect(action.character!.moveX, 0);
          expect(action.character!.moveZ, 0);
        }
      }
    },
  );
  test('unknown goal performs bounded stopped camera scan and can recover', () {
    final map = publishedMap(),
        id = identity(publishedMap()),
        c = VisualGoalController(
          actorShape: profile.actorShape,
          actorOffset: PhysicsPose(),
          profile: profile,
          map: publishedMap(),
          identity: identity(publishedMap()),
        );
    final scans = [for (var t = 0; t < 4; t++) decide(c, t).cameraYaw];
    expect(scans.toSet().length, 4);
    expect(scans.every((y) => y.abs() <= math.pi), true);
    c.accept(
      estimate: VisualEstimate.decode(visible(), profile: profile),
      captured: pose(id, tick: 5),
      tick: 7,
    );
    expect(decide(c, 7).state, VisualMotionState.moving);
    expect(map.mesh.cells, isNotEmpty);
  });
  test(
    'identical full permitted histories yield identical goals and actions',
    () {
      final map = publishedMap(), id = identity(publishedMap());
      final a = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: map,
            identity: id,
          ),
          b = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: map,
            identity: id,
          );
      for (var tick = 0; tick < 40; tick++) {
        if (tick % 5 == 2) {
          for (final c in [a, b]) {
            c.accept(
              estimate: tick == 2
                  ? VisualEstimate.decode(visible(), profile: profile)
                  : VisualEstimate.unknown(profile),
              captured: pose(id, tick: tick - 2),
              tick: tick,
            );
          }
        }
        final x = decide(a, tick), y = decide(b, tick);
        expect(x.state, y.state);
        expect(x.cameraYaw, y.cameraYaw);
        expect(x.goal?.route, y.goal?.route);
        expect(x.character?.moveX, y.character?.moveX);
        expect(x.character?.moveZ, y.character?.moveZ);
      }
    },
  );
  test(
    'clearance pauses and sub-cell cue noise preserve follower progress',
    () {
      final map = publishedMap(),
          id = identity(publishedMap()),
          c = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: publishedMap(),
            identity: identity(publishedMap()),
          );
      c.accept(
        estimate: VisualEstimate.decode(visible(), profile: profile),
        captured: pose(id),
        tick: 2,
      );
      expect(decide(c, 2).state, VisualMotionState.moving);
      final route = c.route;
      c.accept(
        estimate: VisualEstimate.unknown(profile),
        captured: pose(id, tick: 5),
        tick: 7,
      );
      expect(decide(c, 7).state, VisualMotionState.unknownClearance);
      expect(c.route, same(route));
      c.accept(
        estimate: VisualEstimate.decode(
          visible(forward: 3.96),
          profile: profile,
        ),
        captured: pose(id, tick: 10),
        tick: 12,
      );
      expect(decide(c, 12).state, VisualMotionState.moving);
      expect(c.route, same(route));
      expect(map.hash, id.mapHash);
    },
  );
  test(
    'goal changes beyond tolerance replan and reset needs a new identity',
    () {
      final map = publishedMap(),
          id = identity(publishedMap()),
          c = VisualGoalController(
            actorShape: profile.actorShape,
            actorOffset: PhysicsPose(),
            profile: profile,
            map: publishedMap(),
            identity: identity(publishedMap()),
          );
      c.accept(
        estimate: VisualEstimate.decode(visible(), profile: profile),
        captured: pose(id),
        tick: 2,
      );
      decide(c, 2);
      final old = c.route;
      c.accept(
        estimate: VisualEstimate.decode(
          visible(forward: 3.8),
          profile: profile,
        ),
        captured: pose(id, tick: 5),
        tick: 7,
      );
      decide(c, 7);
      expect(c.route, isNot(same(old)));
      expect(() => c.reset(id), throwsArgumentError);
      c.reset(identity(map, stateEpoch: 1));
      expect(c.route, isNull);
      expect(c.belief, isNull);
      expect(
        c.accept(
          estimate: VisualEstimate.decode(visible(), profile: profile),
          captured: pose(id, tick: 10),
          tick: 12,
        ),
        false,
      );
    },
  );
  test('duplicate control ticks cannot advance recovery scan twice', () {
    final map = publishedMap(),
        c = VisualGoalController(
          actorShape: profile.actorShape,
          actorOffset: PhysicsPose(),
          profile: profile,
          map: publishedMap(),
          identity: identity(publishedMap()),
        );
    decide(c, 0);
    expect(() => decide(c, 0), throwsArgumentError);
    expect(map.mesh.cells, isNotEmpty);
  });
  test('capture-relative sideways drift cannot borrow central clearance', () {
    final map = publishedMap(), id = identity(publishedMap());
    final values = visible()
      ..[0] = .8
      ..[56] = 0
      ..[72] = 0;
    final c = VisualGoalController(
      actorShape: profile.actorShape,
      actorOffset: PhysicsPose(),
      profile: profile,
      map: map,
      identity: id,
    );
    c.accept(
      estimate: VisualEstimate.decode(values, profile: profile),
      captured: pose(id),
      tick: 2,
    );
    final action = decide(c, 2, position: const Vec3(.9, .81, .1));
    expect(action.state, VisualMotionState.unknownClearance);
    expect(action.character!.moveX, 0);
    expect(action.character!.moveZ, 0);
  });
  test(
    'vehicle route direction cannot certify mismatched physical heading',
    () {
      final p = VisualNavigationProfile(family: 'vehicle', mode: 'combined'),
          map = publishedMap(radius: p.footprintRadius),
          id = identity(map, family: 'vehicle');
      final c = VisualGoalController(
        actorShape: p.actorShape,
        actorOffset: PhysicsPose(),
        profile: p,
        map: map,
        identity: id,
      );
      c.accept(
        estimate: VisualEstimate.decode(visible(forward: 2.5), profile: p),
        captured: VisualCapturePose(
          identity: id,
          profile: p,
          actorPose: PhysicsPose(position: const Vec3(.1, .81, .1)),
          groundY: 0,
          cameraYaw: 0,
          captureTick: 0,
          worldRevision: 0,
        ),
        tick: 2,
      );
      final d = c.decide(
        tick: 2,
        ownPose: PhysicsPose(
          position: const Vec3(.1, .81, .1),
          rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
        ),
        ownVelocity: const Vec3(1, 0, 0),
        groundY: 0,
      );
      expect(d.state, VisualMotionState.unknownClearance);
      expect(d.vehicle!.brake, 1);
      expect(d.vehicle!.throttle, 0);
      expect(d.vehicle!.steer, 0);
    },
  );
  test(
    'vehicle unknown goal always brakes through the existing typed controller',
    () {
      final p = VisualNavigationProfile(family: 'vehicle', mode: 'combined'),
          map = publishedMap(radius: p.footprintRadius);
      final c = VisualGoalController(
        actorShape: p.actorShape,
        actorOffset: PhysicsPose(),
        profile: p,
        map: map,
        identity: identity(map, family: 'vehicle'),
      );
      final d = decide(c, 0);
      expect(d.vehicle!.brake, 1);
      expect(d.vehicle!.throttle, 0);
      expect(d.character, isNull);
    },
  );
}
