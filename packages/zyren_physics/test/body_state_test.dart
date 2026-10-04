import 'dart:convert';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/src/bindings.dart';
import 'package:zyren_physics/zyren_physics.dart';

Map _native(Map<String, Object?> request) {
  final input = jsonEncode(request).toNativeUtf8();
  try {
    final output = physicsCall(input.cast());
    try {
      return jsonDecode(output.cast<Utf8>().toDartString()) as Map;
    } finally {
      physicsFree(output);
    }
  } finally {
    calloc.free(input);
  }
}

void _same(BodyState actual, BodyState expected) {
  expect(actual.id, expected.id);
  expect(actual.kind, expected.kind);
  expect(actual.pose.position, expected.pose.position);
  expect(actual.pose.json, expected.pose.json);
  expect(actual.velocity, expected.velocity);
  expect(actual.angularVelocity, expected.angularVelocity);
  expect(actual.sleeping, expected.sleeping);
  expect(actual.mass, expected.mass);
  expect(actual.ccdEnabled, expected.ccdEnabled);
  expect(actual.centerOfMass, expected.centerOfMass);
  expect(actual.localCenterOfMass, expected.localCenterOfMass);
  expect(actual.massPropertiesRevision, expected.massPropertiesRevision);
  final a = actual.inverseInertia, b = expected.inverseInertia;
  expect(
    [a.xx, a.yy, a.zz, a.xy, a.xz, a.yz],
    [b.xx, b.yy, b.zz, b.xy, b.xz, b.yz],
  );
}

void main() {
  test('dense step states equal uncached legacy reads for every body kind', () {
    final world = PhysicsWorld(fixedStep: .02);
    final beforeCounts = PhysicsWorld.nativeCounts;
    try {
      final bodies = [
        for (var i = 0; i < BodyKind.values.length; i++)
          world.createBody(
            kind: BodyKind.values[i],
            pose: PhysicsPose(
              position: Vec3(i * 3.0, 4, 0),
              rotation: Quat.axisAngle(const Vec3(1, 2, 3), .7),
            ),
            mass: 2,
            inertia: const Vec3(1, 2, 3),
            centerOfMass: const Vec3(.1, .2, .3),
            velocity: const Vec3(.2, .3, .4),
            angularVelocity: const Vec3(.1, .2, .3),
            ccd: true,
          ),
      ];
      for (final body in bodies) {
        body.addCollider(
          const BoxShape(Vec3(.5, .4, .3)),
          offset: PhysicsPose(position: const Vec3(.1, .2, .3)),
        );
      }
      for (var tick = 0; tick < 120; tick++) {
        if (tick == 60) {
          bodies[1].setMassProperties(
            mass: 3,
            inertia: const Vec3(2, 3, 4),
            centerOfMass: const Vec3(.3, .2, .1),
          );
        }
        bodies[2].setTarget(PhysicsPose(position: Vec3(6, 4, tick * .02)));
        final states = world.step().bodies;
        expect(identical(world.states, states), isTrue);
        final revision = world.revision;
        // Invalidate the Dart snapshot without changing any body value. Each
        // body.state below then decodes the independent native map response.
        world.setGravity(const Vec3(0, -9.81, 0));
        expect(world.revision, revision + 1);
        for (final body in bodies) {
          _same(states.singleWhere((s) => s.id == body.id), body.state);
        }
        final captured = world.states;
        expect(world.revision, revision + 1);
        for (final state in captured) {
          _same(state, states.singleWhere((s) => s.id == state.id));
        }
      }
      for (final body in bodies) {
        body.remove();
      }
      expect(world.states, isEmpty);
      expect(PhysicsWorld.nativeCounts, beforeCounts);
    } finally {
      world.close();
    }
  });

  test('native single-body response stays bounded with unrelated bodies', () {
    final counts = PhysicsWorld.nativeCounts;
    final world =
        _native({
              'op': 'create',
              'gravity': [0, 0, 0],
              'dt': 1 / 60,
            })['value']
            as int;
    try {
      final bodies = [
        for (var i = 0; i < 96; i++)
          _native({
            'op': 'body',
            'world': world,
            'kind': 'dynamic',
            'position': [i, 0, 0],
          })['value'],
      ];
      final response = _native({
        'op': 'bodyState',
        'world': world,
        'body': bodies[47],
      });
      expect(response['error'], isNull);
      expect(response['value'], isA<Map>());
      final all = _native({'op': 'poses', 'world': world})['value'] as List;
      expect(
        response['value'],
        all.singleWhere((s) => s['body'] == bodies[47]),
      );
      expect(jsonEncode(response).length, lessThan(1024));
      _native({'op': 'removeBody', 'world': world, 'body': bodies[47]});
      expect(
        _native({
          'op': 'bodyState',
          'world': world,
          'body': bodies[47],
        })['error'],
        isA<String>(),
      );
      expect(
        _native({
          'op': 'bodyState',
          'world': world,
          'body': 'invalid',
        })['error'],
        isA<String>(),
      );
    } finally {
      _native({'op': 'close', 'world': world});
    }
    expect(PhysicsWorld.nativeCounts, counts);
  });

  test(
    'direct state reflects same-frame writes and never returns a cached pose',
    () {
      final world = PhysicsWorld(gravity: Vec3.zero);
      try {
        final body = world.createBody(mass: 2, inertia: Vec3.one, ccd: true);
        final collider = body.addCollider(const SphereShape(.25));
        void check() =>
            _same(body.state, world.states.singleWhere((s) => s.id == body.id));
        check();
        final old = body.state;
        body.teleport(PhysicsPose(position: const Vec3(2, 3, 4)));
        check();
        expect(old.pose.position, Vec3.zero);
        body.setVelocity(const Vec3(1, 2, 3));
        check();
        body.setAngularVelocity(const Vec3(.2, .3, .4));
        check();
        body.setMassProperties(mass: 3, inertia: Vec3.one);
        check();
        collider.configure(density: 2);
        check();
        body.sleep();
        check();
        expect(body.state.sleeping, isTrue);
        body.wake();
        body.applyImpulse(const Vec3(2, 0, 0));
        check();
        world.step();
        check();
        body.remove();
        expect(() => body.state, throwsStateError);
      } finally {
        world.close();
      }
    },
  );

  test(
    'kinematic velocity and restored handles match complete native states',
    () {
      final world = PhysicsWorld(gravity: Vec3.zero, fixedStep: 1 / 60);
      try {
        final body = world.createBody(
          kind: BodyKind.kinematicPosition,
          mass: 3,
          inertia: Vec3.one,
        );
        body.setTarget(PhysicsPose(position: const Vec3(0, 0, 1)));
        world.step();
        _same(body.state, world.states.single);
        expect(body.state.velocity.z, closeTo(60, 1e-4));
        body.restoreMotion(
          pose: PhysicsPose(position: const Vec3(0, 2, 1)),
          velocity: const Vec3(0, -2, 3),
          angularVelocity: Vec3.zero,
          sleeping: false,
        );
        _same(body.state, world.states.single);
        final checkpoint = world.snapshot(), id = body.id;
        body.teleport(PhysicsPose(position: const Vec3(100, 0, 0)));
        world.restore(checkpoint);
        expect(() => body.state, throwsStateError);
        final restored = world.body(id, BodyKind.kinematicPosition);
        _same(restored.state, world.states.single);
        expect(restored.state.pose.position, const Vec3(0, 2, 1));
        expect(() => world.body(id, BodyKind.dynamic), throwsArgumentError);
        restored.setTarget(PhysicsPose(position: const Vec3(0, 2, 2)));
        world.step();
        _same(restored.state, world.states.single);
        expect(restored.state.velocity.z, closeTo(60, 1e-4));
        restored.remove();
        expect(() => world.body(id), throwsStateError);
        world.close();
        expect(() => restored.state, throwsStateError);
      } finally {
        world.close();
      }
    },
  );
}
