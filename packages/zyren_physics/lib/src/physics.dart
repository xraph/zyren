import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart';

part 'character_controller.dart';

Object? _call(Map<String, Object?> request) {
  final encoded = jsonEncode(request);
  if (utf8.encode(encoded).length > 16 * 1024 * 1024) {
    throw ArgumentError('Physics request exceeds 16 MiB.');
  }
  final input = encoded.toNativeUtf8();
  try {
    final output = physicsCall(input.cast());
    if (output == nullptr) {
      throw StateError('Physics returned a null response.');
    }
    try {
      final response = jsonDecode(output.cast<Utf8>().toDartString()) as Map;
      if (response['protocol'] != 1) {
        throw const PhysicsException(
          'Incompatible native physics asset. Rebuild with the current package and one Dart SDK.',
        );
      }
      if (response['error'] case final String error) {
        throw PhysicsException(error);
      }
      return response['value'];
    } finally {
      physicsFree(output);
    }
  } finally {
    calloc.free(input);
  }
}

final class PhysicsException implements Exception {
  final String message;
  const PhysicsException(this.message);
  @override
  String toString() => 'PhysicsException: $message';
}

enum BodyKind { fixed, dynamic, kinematicPosition, kinematicVelocity }

enum JointKind {
  hinge,
  slider,
  fixed,
  spherical,
  spring,

  /// A maximum-distance rope constraint. The anchors can move closer together.
  distance,
}

enum MotorAxis { linearX, angularX, angularY, angularZ }

final class PhysicsPose {
  final Vec3 position;
  final Quat rotation;
  PhysicsPose({this.position = Vec3.zero, Quat rotation = Quat.identity})
    : rotation = rotation.normalized() {
    if (!position.isFinite) throw ArgumentError('Position must be finite.');
  }
  Map<String, Object> get json => {
    'position': position.storage,
    'rotation': [rotation.x, rotation.y, rotation.z, rotation.w],
  };
  PhysicsPose interpolate(PhysicsPose other, double alpha) {
    var q = other.rotation;
    if (rotation.x * q.x +
            rotation.y * q.y +
            rotation.z * q.z +
            rotation.w * q.w <
        0) {
      q = Quat(-q.x, -q.y, -q.z, -q.w);
    }
    return PhysicsPose(
      position: position * (1 - alpha) + other.position * alpha,
      rotation: Quat(
        rotation.x * (1 - alpha) + q.x * alpha,
        rotation.y * (1 - alpha) + q.y * alpha,
        rotation.z * (1 - alpha) + q.z * alpha,
        rotation.w * (1 - alpha) + q.w * alpha,
      ),
    );
  }
}

sealed class ColliderShape {
  const ColliderShape();
  Map<String, Object> get json;
}

final class BoxShape extends ColliderShape {
  final Vec3 halfExtents;
  const BoxShape(this.halfExtents);
  @override
  Map<String, Object> get json => {
    'type': 'box',
    'halfExtents': halfExtents.storage,
  };
}

final class SphereShape extends ColliderShape {
  final double radius;
  const SphereShape(this.radius);
  @override
  Map<String, Object> get json => {'type': 'sphere', 'radius': radius};
}

final class CapsuleShape extends ColliderShape {
  final double halfHeight, radius;
  const CapsuleShape({required this.halfHeight, required this.radius});
  @override
  Map<String, Object> get json => {
    'type': 'capsule',
    'halfHeight': halfHeight,
    'radius': radius,
  };
}

final class ConvexShape extends ColliderShape {
  final List<Vec3> vertices;
  ConvexShape(Iterable<Vec3> vertices) : vertices = List.unmodifiable(vertices);
  @override
  Map<String, Object> get json => {
    'type': 'convex',
    'vertices': vertices.map((p) => p.storage).toList(),
  };
}

final class TriangleMeshShape extends ColliderShape {
  final List<Vec3> vertices;
  final List<List<int>> triangles;
  TriangleMeshShape(Iterable<Vec3> vertices, Iterable<List<int>> triangles)
    : vertices = List.unmodifiable(vertices),
      triangles = List.unmodifiable(triangles.map(List<int>.unmodifiable));
  @override
  Map<String, Object> get json => {
    'type': 'mesh',
    'vertices': vertices.map((p) => p.storage).toList(),
    'triangles': triangles,
  };
}

final class CompoundChild {
  final ColliderShape shape;
  final PhysicsPose pose;
  CompoundChild(this.shape, {PhysicsPose? pose}) : pose = pose ?? PhysicsPose();
}

final class CompoundShape extends ColliderShape {
  final List<CompoundChild> children;
  CompoundShape(Iterable<CompoundChild> children)
    : children = List.unmodifiable(children);
  @override
  Map<String, Object> get json => {
    'type': 'compound',
    'children': children
        .map((c) => {'shape': c.shape.json, ...c.pose.json})
        .toList(),
  };
}

/// Native world-space inverse angular inertia, including locked rotation axes.
final class PhysicsInverseInertia {
  final double xx, yy, zz, xy, xz, yz;
  PhysicsInverseInertia._(List values)
    : xx = (values[0] as num).toDouble(),
      yy = (values[1] as num).toDouble(),
      zz = (values[2] as num).toDouble(),
      xy = (values[3] as num).toDouble(),
      xz = (values[4] as num).toDouble(),
      yz = (values[5] as num).toDouble();
  Vec3 apply(Vec3 v) => Vec3(
    xx * v.x + xy * v.y + xz * v.z,
    xy * v.x + yy * v.y + yz * v.z,
    xz * v.x + yz * v.y + zz * v.z,
  );
}

/// One additive command in an atomically validated native batch.
final class PhysicsImpulse {
  final PhysicsBody body;
  final Vec3 linear, angular;
  final Vec3? at;
  final bool wake;
  const PhysicsImpulse(
    this.body, {
    this.linear = Vec3.zero,
    this.angular = Vec3.zero,
    this.at,
    this.wake = true,
  });
}

/// A force held over the next native integration, then removed automatically.
final class PhysicsForce {
  final PhysicsBody body;
  final Vec3 force, torque;
  final Vec3? at;
  final bool wake;
  const PhysicsForce(
    this.body, {
    this.force = Vec3.zero,
    this.torque = Vec3.zero,
    this.at,
    this.wake = true,
  });
}

/// Owns one transient contribution. Other force sources remain independent.
final class PhysicsForceBatch extends Registration {
  final PhysicsWorld world;
  final int _id, _epoch;
  PhysicsForceBatch._(this.world, this._id, this._epoch)
    : super(() {
        if (!world.isClosed && world._epoch == _epoch) {
          world._send('cancelForces', {'batch': _id});
        }
      });
  void removeBody(PhysicsBody body) {
    if (isDisposed || world.isClosed || world._epoch != _epoch) return;
    world._check(body);
    world._send('cancelForces', {'batch': _id, 'body': body.id});
  }
}

final class BodyState {
  final int id;
  final BodyKind kind;
  final PhysicsPose pose;
  final Vec3 velocity, angularVelocity;
  final bool sleeping, ccdEnabled;
  final double mass;
  final Vec3 centerOfMass, localCenterOfMass;
  final PhysicsInverseInertia inverseInertia;

  /// Conservative world-wide mass mutation revision. Restore creates a new epoch.
  final int massPropertiesRevision;
  BodyState._(Map data)
    : id = data['body'] as int,
      kind = BodyKind.values.byName(data['kind'] as String),
      pose = PhysicsPose(
        position: _vec(data['position']),
        rotation: _quat(data['rotation']),
      ),
      velocity = _vec(data['velocity']),
      angularVelocity = _vec(data['angularVelocity']),
      sleeping = data['sleeping'] as bool,
      ccdEnabled = data['ccd'] as bool,
      mass = (data['mass'] as num).toDouble(),
      centerOfMass = _vec(data['centerOfMass']),
      localCenterOfMass = _vec(data['localCenterOfMass']),
      inverseInertia = PhysicsInverseInertia._(data['inverseInertia'] as List),
      massPropertiesRevision = data['massPropertiesRevision'] as int;
}

Vec3 _vec(Object? value) {
  final a = value as List;
  return Vec3(
    (a[0] as num).toDouble(),
    (a[1] as num).toDouble(),
    (a[2] as num).toDouble(),
  );
}

Quat _quat(Object? value) {
  final a = value as List;
  return Quat(
    (a[0] as num).toDouble(),
    (a[1] as num).toDouble(),
    (a[2] as num).toDouble(),
    (a[3] as num).toDouble(),
  );
}

final class PhysicsEvent {
  final String kind;
  final int? collider1, collider2;
  final bool started, sensor;
  final Vec3 force;
  final double magnitude;
  PhysicsEvent._(Map data)
    : kind = data['kind'] as String,
      collider1 = data['collider1'] as int?,
      collider2 = data['collider2'] as int?,
      started = data['started'] as bool? ?? false,
      sensor = data['sensor'] as bool? ?? false,
      force = data['force'] == null ? Vec3.zero : _vec(data['force']),
      magnitude = (data['magnitude'] as num? ?? 0).toDouble();
}

final class PhysicsStep {
  final List<BodyState> bodies;
  final List<PhysicsEvent> events;
  PhysicsStep._(Map data)
    : bodies = List.unmodifiable(
        (data['poses'] as List).map((v) => BodyState._(v as Map)),
      ),
      events = List.unmodifiable(
        (data['events'] as List).map((v) => PhysicsEvent._(v as Map)),
      );
}

final class QueryHit {
  final int collider;
  final int? body;

  /// Distance for ray casts; seconds for shape casts.
  final double time;

  /// Zero when a zero-distance solid hit has no defined surface normal.
  final Vec3 normal;
  QueryHit._(Map data)
    : collider = data['collider'] as int,
      body = data['body'] as int?,
      time = (data['time'] as num).toDouble(),
      normal = _vec(data['normal']);
}

final class QueryFilter {
  final PhysicsBody? excludeBody;
  final bool excludeSensors;
  final int membership, filter;
  const QueryFilter({
    this.excludeBody,
    this.excludeSensors = false,
    this.membership = 0xffffffff,
    this.filter = 0xffffffff,
  });
  Map<String, Object> get json => {
    'excludeSensors': excludeSensors,
    'membership': membership,
    'filter': filter,
    if (excludeBody != null) 'excludeBody': excludeBody!.id,
  };
}

/// One normalized-distance ray in a [PhysicsWorld.rayCastBatch] request.
final class PhysicsRay {
  final Vec3 origin, direction;
  final double maxDistance;
  final bool solid;
  const PhysicsRay({
    required this.origin,
    required this.direction,
    this.maxDistance = 1000,
    this.solid = true,
  });

  Map<String, Object> get _json => {
    'origin': origin.storage,
    'direction': direction.storage,
    'maxDistance': maxDistance,
    'solid': solid,
  };
}

final class DebugLine {
  final String kind;
  final Vec3 a, b;
  final List<double> color;
  DebugLine._(Map data)
    : kind = data['kind'] as String,
      a = _vec(data['a']),
      b = _vec(data['b']),
      color = List.unmodifiable(
        (data['color'] as List).map((x) => (x as num).toDouble()),
      );
}

final class PhysicsSnapshot {
  final String _encoded;
  PhysicsSnapshot._(Object? data) : _encoded = jsonEncode(data);

  /// Snapshots contain native engine state. Restore only snapshots you trust.
  String encode() => _encoded;
  factory PhysicsSnapshot.decode(String encoded) {
    if (encoded.length > 16 * 1024 * 1024) {
      throw ArgumentError('Snapshot exceeds 16 MiB.');
    }
    return PhysicsSnapshot._(jsonDecode(encoded));
  }
}

final class PhysicsWorld implements Finalizable {
  static final _finalizer = NativeFinalizer(Native.addressOf(physicsFinalize));
  final double fixedStep;
  late final int _id;
  bool _closed = false;
  int _epoch = 0, _revision = 0, _completedSteps = 0;
  final Map<int, PhysicsBody> _bodies = {};
  List<BodyState>? _stateSnapshot;
  Map<int, BodyState>? _bodyStateSnapshot;
  PhysicsWorld({
    Vec3 gravity = const Vec3(0, -9.81, 0),
    this.fixedStep = 1 / 60,
  }) {
    _id =
        _call({'op': 'create', 'gravity': gravity.storage, 'dt': fixedStep})
            as int;
    _finalizer.attach(this, Pointer<Void>.fromAddress(_id), detach: this);
  }
  bool get isClosed => _closed;

  /// Increases before every potentially mutating native operation, even failures.
  int get revision => _revision;
  int get completedSteps => _completedSteps;
  Vec3 get gravity => _vec((_send('worldInfo') as Map)['gravity']);

  /// Validate the entire command list natively before applying any impulse.
  /// External forces are preserved. This method never advances physics.
  void applyImpulses(
    List<PhysicsImpulse> impulses, {
    required int expectedRevision,
  }) {
    if (_closed || expectedRevision != _revision) {
      throw StateError('Physics impulse batch is stale.');
    }
    if (impulses.length > 16384) {
      throw ArgumentError('Impulse batch exceeds 16384 commands.');
    }
    for (final impulse in impulses) {
      _check(impulse.body);
    }
    _send('impulses', {
      'commands': [
        for (final impulse in impulses)
          {
            'body': impulse.body.id,
            'linear': impulse.linear.storage,
            'angular': impulse.angular.storage,
            if (impulse.at != null) 'point': impulse.at!.storage,
            'wake': impulse.wake,
          },
      ],
    });
  }

  /// Transform the entire world's poses, velocities, gravity and external loads.
  /// Contacts refresh on the next query/step. Local collider and joint frames stay local.
  void rebase(PhysicsPose oldToNew, {required int expectedRevision}) {
    if (_closed || expectedRevision != _revision) {
      throw StateError('Physics rebase is stale.');
    }
    _send('rebase', oldToNew.json);
  }

  /// Queue an additive contribution for the next native step. All commands
  /// validate before publication. Close the returned batch to cancel only it.
  PhysicsForceBatch queueForces(
    List<PhysicsForce> forces, {
    required int expectedRevision,
  }) {
    if (_closed || expectedRevision != _revision) {
      throw StateError('Physics force batch is stale.');
    }
    if (forces.length > 16384) {
      throw ArgumentError('Force batch exceeds 16384 commands.');
    }
    for (final force in forces) {
      _check(force.body);
    }
    final id =
        _send('queueForces', {
              'commands': [
                for (final force in forces)
                  {
                    'body': force.body.id,
                    'linear': force.force.storage,
                    'angular': force.torque.storage,
                    if (force.at != null) 'point': force.at!.storage,
                    'wake': force.wake,
                  },
              ],
            })
            as int;
    return PhysicsForceBatch._(this, id, _epoch);
  }

  Object? _send(String op, [Map<String, Object?> args = const {}]) {
    if (_closed) throw StateError('Physics world is closed.');
    // Only proven read operations preserve a completed native snapshot.
    // Queries can refresh collision state, so they also invalidate it. Clear
    // before the call because a failing native operation may have mutated state.
    if (op != 'worldInfo' &&
        op != 'poses' &&
        op != 'bodyState' &&
        op != 'snapshot' &&
        op != 'debug' &&
        op != 'drainEvents') {
      _stateSnapshot = null;
      _revision++;
      _bodyStateSnapshot = null;
    }
    return _call({'op': op, 'world': _id, ...args});
  }

  void _check(PhysicsBody body) {
    if (!identical(body.world, this) ||
        body._epoch != _epoch ||
        !identical(_bodies[body.id], body)) {
      throw StateError(
        'Body is removed, restored or belongs to another world.',
      );
    }
  }

  PhysicsBody createBody({
    BodyKind kind = BodyKind.dynamic,
    PhysicsPose? pose,
    Vec3 velocity = Vec3.zero,
    Vec3 angularVelocity = Vec3.zero,
    double linearDamping = 0,
    double angularDamping = 0,
    bool ccd = false,
    bool canSleep = true,
    double? mass,
    Vec3? inertia,
    Vec3 centerOfMass = Vec3.zero,
  }) {
    final id =
        _send('body', {
              'kind': kind.name,
              ...(pose ?? PhysicsPose()).json,
              'velocity': velocity.storage,
              'angularVelocity': angularVelocity.storage,
              'linearDamping': linearDamping,
              'angularDamping': angularDamping,
              'ccd': ccd,
              'canSleep': canSleep,
              'mass': ?mass,
              if (inertia != null) 'inertia': inertia.storage,
              'centerOfMass': centerOfMass.storage,
            })
            as int;
    final body = PhysicsBody._(this, id, kind, _epoch);
    _bodies[id] = body;
    return body;
  }

  void setGravity(Vec3 value) => _send('gravity', {'value': value.storage});
  PhysicsStep step() {
    final result = PhysicsStep._(_send('step') as Map);
    _completedSteps++;
    _stateSnapshot = result.bodies;
    return result;
  }

  /// Consume transitions produced by queries without advancing simulation.
  List<PhysicsEvent> drainEvents() => List.unmodifiable(
    (_send('drainEvents') as List).map((e) => PhysicsEvent._(e as Map)),
  );

  /// Immutable body states at the most recent native mutation boundary.
  ///
  /// Reuses a completed step response until any potentially mutating operation.
  /// Body writes and collision queries invalidate it before entering native code.
  List<BodyState> get states {
    if (_closed) throw StateError('Physics world is closed.');
    if (_stateSnapshot case final snapshot?) return snapshot;
    final snapshot = List<BodyState>.unmodifiable(
      (_send('poses') as List).map((v) => BodyState._(v as Map)),
    );
    _bodyStateSnapshot = null;
    return _stateSnapshot = snapshot;
  }

  BodyState _bodyState(int id) {
    if (_closed) throw StateError('Physics world is closed.');
    final states = _bodyStateSnapshot ??= {
      for (final state in _stateSnapshot ?? const <BodyState>[])
        state.id: state,
    };
    return states.putIfAbsent(
      id,
      () => BodyState._(_send('bodyState', {'body': id}) as Map),
    );
  }

  PhysicsSnapshot snapshot() => PhysicsSnapshot._(_send('snapshot'));

  /// Restore invalidates every body, collider and joint handle from this world.
  void restore(PhysicsSnapshot snapshot) {
    _send('restore', {'snapshot': jsonDecode(snapshot._encoded)});
    _epoch++;
    _bodies.clear();
  }

  /// Reacquire a body after restoration using its snapshot ID.
  PhysicsBody body(int id, [BodyKind? kind]) {
    final BodyState state;
    try {
      state = _bodyState(id);
    } on PhysicsException catch (error) {
      if (error.message == 'body does not belong to this world' || id < 1) {
        throw StateError('Body missing from snapshot.');
      }
      rethrow;
    }
    if (kind != null && kind != state.kind) {
      throw ArgumentError('Body kind differs from snapshot.');
    }
    return _bodies.putIfAbsent(
      id,
      () => PhysicsBody._(this, id, state.kind, _epoch),
    );
  }

  void close() {
    if (_closed) return;
    _send('close');
    _finalizer.detach(this);
    _closed = true;
    _epoch++;
    _bodies.clear();
  }

  static Map<String, int> get nativeCounts =>
      (_call({'op': 'counts'}) as Map).cast<String, int>();
  List<DebugLine> debugLines() => List.unmodifiable(
    (_send('debug') as List).map((v) => DebugLine._(v as Map)),
  );
  void _filter(QueryFilter filter) {
    if (filter.excludeBody case final body?) _check(body);
  }

  QueryHit? rayCast({
    required Vec3 origin,
    required Vec3 direction,
    double maxDistance = 1000,
    bool solid = true,
    QueryFilter filter = const QueryFilter(),
  }) {
    _filter(filter);
    final hit = _send('query', {
      'kind': 'ray',
      'origin': origin.storage,
      'direction': direction.storage,
      'maxDistance': maxDistance,
      'solid': solid,
      ...filter.json,
    });
    return hit == null ? null : QueryHit._(hit as Map);
  }

  /// Cast up to 256 rays through one native query boundary.
  ///
  /// Results keep input order, including misses. All rays share [filter] and
  /// observe the same collision state; no simulation step occurs between rays.
  List<QueryHit?> rayCastBatch(
    List<PhysicsRay> rays, {
    QueryFilter filter = const QueryFilter(),
  }) {
    if (rays.length > 256) {
      throw ArgumentError('Ray batch exceeds 256 queries.');
    }
    _filter(filter);
    return List.unmodifiable(
      (_send('query', {
                'kind': 'rays',
                'rays': [for (final ray in rays) ray._json],
                ...filter.json,
              })
              as List)
          .map((hit) => hit == null ? null : QueryHit._(hit as Map)),
    );
  }

  QueryHit? shapeCast({
    required ColliderShape shape,
    required PhysicsPose pose,
    required Vec3 velocity,
    double maxTime = 1,
    QueryFilter filter = const QueryFilter(),
  }) {
    _filter(filter);
    final hit = _send('query', {
      'kind': 'shape',
      'shape': shape.json,
      ...pose.json,
      'velocity': velocity.storage,
      'maxTime': maxTime,
      ...filter.json,
    });
    return hit == null ? null : QueryHit._(hit as Map);
  }

  List<int> overlap({
    required ColliderShape shape,
    required PhysicsPose pose,
    QueryFilter filter = const QueryFilter(),
  }) {
    _filter(filter);
    return List.unmodifiable(
      (_send('query', {
                'kind': 'overlap',
                'shape': shape.json,
                ...pose.json,
                ...filter.json,
              })
              as List)
          .cast<int>(),
    );
  }

  PhysicsJoint createJoint({
    required PhysicsBody body1,
    required PhysicsBody body2,
    required JointKind kind,
    Vec3 axis = const Vec3(0, 1, 0),
    Vec3 anchor1 = Vec3.zero,
    Vec3 anchor2 = Vec3.zero,
    PhysicsPose? frame1,
    PhysicsPose? frame2,
    bool contacts = false,
    List<double>? limits,
    MotorAxis? motorAxis,
    double? motorVelocity,
    double? motorPosition,
    double motorFactor = 1,
    double maxForce = 1000,
    double length = 1,
    double stiffness = 10,
    double damping = 1,
  }) {
    _check(body1);
    _check(body2);
    final id =
        _send('joint', {
              'body1': body1.id,
              'body2': body2.id,
              'kind': kind.name,
              'axis': axis.storage,
              'anchor1': anchor1.storage,
              'anchor2': anchor2.storage,
              'frame1': (frame1 ?? PhysicsPose()).json,
              'frame2': (frame2 ?? PhysicsPose()).json,
              'contacts': contacts,
              'limits': ?limits,
              if (motorAxis != null) 'motorAxis': motorAxis.name,
              'motorVelocity': ?motorVelocity,
              'motorPosition': ?motorPosition,
              'motorFactor': motorFactor,
              'maxForce': maxForce,
              'length': length,
              'stiffness': stiffness,
              'damping': damping,
            })
            as int;
    return PhysicsJoint._(this, id, _epoch);
  }
}

final class PhysicsBody {
  final PhysicsWorld world;
  final int id, _epoch;
  final BodyKind kind;
  PhysicsBody._(this.world, this.id, this.kind, this._epoch);
  bool get isAlive =>
      !world.isClosed &&
      _epoch == world._epoch &&
      identical(world._bodies[id], this);
  void _update(String action, [Map<String, Object?> args = const {}]) {
    world._check(this);
    world._send('bodyUpdate', {'body': id, 'action': action, ...args});
  }

  PhysicsCollider addCollider(
    ColliderShape shape, {
    PhysicsPose? offset,
    double friction = .5,
    double restitution = 0,
    double density = 1,
    bool sensor = false,
    int membership = 0xffffffff,
    int filter = 0xffffffff,
  }) {
    world._check(this);
    final id =
        world._send('collider', {
              'body': this.id,
              'shape': shape.json,
              ...(offset ?? PhysicsPose()).json,
              'friction': friction,
              'restitution': restitution,
              'density': density,
              'sensor': sensor,
              'membership': membership,
              'filter': filter,
            })
            as int;
    return PhysicsCollider._(world, id, _epoch);
  }

  void teleport(PhysicsPose pose, {bool resetVelocity = true}) =>
      _update('teleport', {...pose.json, 'resetVelocity': resetVelocity});

  /// Restores checkpoint motion without replacing the body or advancing time.
  /// Position-driven kinematic velocity is restored as derived state; future
  /// movement still comes from [setTarget]. All native inputs validate first.
  void restoreMotion({
    required PhysicsPose pose,
    required Vec3 velocity,
    required Vec3 angularVelocity,
    required bool sleeping,
  }) => _update('restoreMotion', {
    ...pose.json,
    'velocity': velocity.storage,
    'angularVelocity': angularVelocity.storage,
    'sleeping': sleeping,
  });

  void setTarget(PhysicsPose pose) => _update('target', pose.json);
  void setVelocity(Vec3 value) => _update('velocity', {'value': value.storage});
  void setAngularVelocity(Vec3 value) =>
      _update('angularVelocity', {'value': value.storage});
  void addForce(Vec3 value, {Vec3? at}) => _update(
    at == null ? 'force' : 'forceAt',
    {'value': value.storage, if (at != null) 'point': at.storage},
  );
  void applyImpulse(Vec3 value, {Vec3? at}) => _update(
    at == null ? 'impulse' : 'impulseAt',
    {'value': value.storage, if (at != null) 'point': at.storage},
  );
  void addTorque(Vec3 value) => _update('torque', {'value': value.storage});
  void applyTorqueImpulse(Vec3 value) =>
      _update('torqueImpulse', {'value': value.storage});
  void setDamping({double linear = 0, double angular = 0}) =>
      _update('damping', {'linear': linear, 'angular': angular});

  /// Mass and inertia are additional to collider density contributions.
  void setMassProperties({
    required double mass,
    required Vec3 inertia,
    Vec3 centerOfMass = Vec3.zero,
  }) => _update('mass', {
    'mass': mass,
    'inertia': inertia.storage,
    'centerOfMass': centerOfMass.storage,
  });
  void clearForces() => _update('clearForces');
  void sleep() => _update('sleep');
  void wake() => _update('wake');
  BodyState get state {
    world._check(this);
    return world._bodyState(id);
  }

  void remove() {
    world._check(this);
    world._send('removeBody', {'body': id});
    world._bodies.remove(id);
  }
}

final class PhysicsCollider {
  final PhysicsWorld world;
  final int id, _epoch;
  bool _removed = false;
  PhysicsCollider._(this.world, this.id, this._epoch);
  void configure({
    double friction = .5,
    double restitution = 0,
    double density = 1,
    bool sensor = false,
    int membership = 0xffffffff,
    int filter = 0xffffffff,
  }) {
    if (_removed || _epoch != world._epoch) {
      throw StateError('Collider handle is stale.');
    }
    world._send('colliderUpdate', {
      'collider': id,
      'friction': friction,
      'restitution': restitution,
      'density': density,
      'sensor': sensor,
      'membership': membership,
      'filter': filter,
    });
  }

  void remove() {
    if (_removed || _epoch != world._epoch) {
      throw StateError('Collider handle is stale.');
    }
    world._send('removeCollider', {'collider': id});
    _removed = true;
  }
}

final class PhysicsJoint {
  final PhysicsWorld world;
  final int id, _epoch;
  bool _removed = false;
  PhysicsJoint._(this.world, this.id, this._epoch);
  void setMotor({
    MotorAxis axis = MotorAxis.angularX,
    double position = 0,
    double velocity = 0,
    double stiffness = 0,
    double damping = 1,
    double maxForce = 1000,
  }) {
    if (_removed || _epoch != world._epoch) {
      throw StateError('Joint handle is stale.');
    }
    world._send('jointUpdate', {
      'joint': id,
      'axis': axis.name,
      'position': position,
      'velocity': velocity,
      'stiffness': stiffness,
      'damping': damping,
      'maxForce': maxForce,
    });
  }

  void remove() {
    if (_removed || _epoch != world._epoch) {
      throw StateError('Joint handle is stale.');
    }
    world._send('removeJoint', {'joint': id});
    _removed = true;
  }
}
