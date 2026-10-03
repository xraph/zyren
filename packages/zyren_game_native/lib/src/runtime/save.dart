part of '../../runtime.dart';

GameSession _checkpointSession(GameLevelRuntime owner) {
  final session = owner.simulation?.session;
  if (owner.isClosed ||
      owner.error != null ||
      session == null ||
      !owner._setupReady ||
      owner._restoringCheckpoint) {
    throw StateError(
      'Native checkpoints require a healthy initialized tick boundary.',
    );
  }
  return session;
}

GameSave _saveRuntime(GameLevelRuntime owner) {
  final session = _checkpointSession(owner);
  final save = session.save();
  _validateCheckpointTopology(owner, session, save);
  return save;
}

Object? _canonicalNative(Object? value) => value is Map<String, Object?>
    ? {
        for (final key in value.keys.toList()..sort())
          key: _canonicalNative(value[key]),
      }
    : value is List
    ? value.map(_canonicalNative).toList()
    : value;

void _validateCheckpointTopology(
  GameLevelRuntime owner,
  GameSession session,
  GameSave save,
) {
  final authored = owner.project.levels
      .singleWhere((l) => l.id == session.levelId)
      .entities;
  final records = {for (final e in save.entities) e.id: e};
  const nativeTypes = {
    'game.collider',
    'game.character',
    'game.character-rig',
    'game.vehicle',
    'game.input',
    'game.camera',
  };
  if (save.entities.length != authored.length ||
      records.length != authored.length ||
      !records.keys.toSet().containsAll(authored.map((e) => e.id)) ||
      authored.any(
        (e) =>
            records[e.id]!.nodeId != e.nodeId ||
            jsonEncode(
                  _canonicalNative(
                    e.components
                        .where((c) => nativeTypes.contains(c.type))
                        .map((c) => c.toJson())
                        .toList(),
                  ),
                ) !=
                jsonEncode(
                  _canonicalNative(
                    records[e.id]!.components
                        .where((c) => nativeTypes.contains(c.type))
                        .map((c) => c.toJson())
                        .toList(),
                  ),
                ),
      )) {
    throw const FormatException(
      'Native checkpoint topology or controller definitions differ.',
    );
  }
}

void _restoreRuntime(GameLevelRuntime owner, GameSave save) {
  final session = _checkpointSession(owner);
  _validateCheckpointTopology(owner, session, save);
  owner._restoringCheckpoint = true;
  var committed = false;
  final restoreEpoch = session.epoch;
  try {
    session.restore(save);
    committed = true;
    final state = owner._restoredNative!;
    for (final input in owner._inputs.values) {
      input.releaseEveryDevice();
    }
    for (final registration in owner._actorRegistrations.reversed) {
      registration();
    }
    owner._actorRegistrations.clear();
    owner._characters.clear();
    owner._primitiveCharacters.clear();
    owner._vehicleControllers.clear();
    owner._inputs.clear();
    owner._cameras.clear();
    owner._cameraModes.clear();
    owner._characterLeases.clear();
    owner._vehicleLeases.clear();
    owner._possession = null;
    owner._controlled = null;
    owner._inputActor = null;
    _PlaySetup(owner).bind(session, restoring: true);
    for (final entry in owner._primitiveCharacters.entries) {
      final data = state.primitives[entry.key.id]!;
      entry.value.verticalSpeed = (data['verticalSpeed'] as num).toDouble();
      entry.value.grounded = data['grounded'] as bool;
    }
    for (final entry in owner._vehicleControllers.entries) {
      entry.value.restoreState(state.vehicles[entry.key.id]!);
    }
    GameEntityHandle? handle(String? id) => id == null
        ? null
        : session.entities.entities
              .where((e) => e.handle.id == id)
              .firstOrNull
              ?.handle;
    owner._controlled = handle(state.controlled);
    owner._selection = handle(state.selection);
    if (!session.paused) owner._restoreControl();
    GameVehiclePresentationSystem(owner._vehicles!).fixedUpdate(session);
    for (final rig in owner._cameras) {
      rig.follow(owner._controlled);
      if (owner._controlled != null &&
          owner._vehicleControllers.containsKey(owner._controlled)) {
        rig.mode = GameCameraMode.vehicle;
      }
      rig.update(const CharacterIntent());
    }
    for (final callback in owner._restoredListeners.toList()) {
      if (owner._restoredListeners.contains(callback)) callback();
    }
    owner._publish();
  } catch (error) {
    // A staging rejection leaves the live checkpoint intact. A committed restore
    // with failed host rebinding cannot safely advance and remains closable.
    if (committed || session.epoch != restoreEpoch) {
      owner._checkpointFault = error;
      session.invalidatePending();
      owner.simulation!.physics.paused = true;
      try {
        if (!session.paused) {
          session.pause();
        } else {
          session.resume();
        }
      } catch (_) {}
      owner.actions?.releaseEveryDevice();
      owner._publish();
    }
    rethrow;
  } finally {
    owner._restoringCheckpoint = false;
    owner._restoredNative = null;
    owner._publish();
  }
}

final class _NativeLevelState {
  final Map<String, PhysicsPose> poses;
  final Map<String, Vec3> velocities, angular;
  final Map<String, bool> active, visible, sleeping;
  final Map<String, Map<String, Object?>> primitives, motors, vehicles;
  final String? controlled, selection;
  _NativeLevelState(
    this.poses,
    this.velocities,
    this.angular,
    this.active,
    this.visible,
    this.sleeping,
    this.primitives,
    this.motors,
    this.vehicles,
    this.controlled,
    this.selection,
  );
}

final class _NativeLevelCodec extends GameStateCodec<_NativeLevelState> {
  final GameLevelRuntime owner;
  _NativeLevelCodec(this.owner);
  @override
  String get id => 'game.native-level';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {
    'bodies': {
      for (final e in owner._bodies.entries)
        e.key: {
          'position': e.value.state.pose.position.storage,
          'rotation': [
            e.value.state.pose.rotation.x,
            e.value.state.pose.rotation.y,
            e.value.state.pose.rotation.z,
            e.value.state.pose.rotation.w,
          ],
          'velocity': e.value.state.velocity.storage,
          'angular': e.value.state.angularVelocity.storage,
          'sleeping': e.value.state.sleeping,
        },
    },
    'active': {
      for (final e
          in owner.project.levels
              .singleWhere((l) => l.id == session.levelId)
              .entities)
        e.id: owner._active[e.id] ?? true,
    },
    'visible': {
      for (final e
          in owner.project.levels
              .singleWhere((l) => l.id == session.levelId)
              .entities)
        e.id: owner.objects[e.nodeId]?.visible ?? true,
    },
    'primitives': {
      for (final e in owner._primitiveCharacters.entries)
        e.key.id: {
          'verticalSpeed': e.value.verticalSpeed,
          'grounded': e.value.grounded,
        },
    },
    'motors': {
      for (final e in owner._characters.entries)
        e.key.id: e.value.motor.captureState(),
    },
    'vehicles': {
      for (final e in owner._vehicleControllers.entries)
        e.key.id: e.value.captureState(),
    },
    'controlled': owner._controlled?.id,
    'selection': owner._selection?.id,
  };
  @override
  _NativeLevelState prepare(GameSession session, Map<String, Object?> data) {
    if (!owner._restoringCheckpoint) {
      throw StateError(
        'Restore native games through GameLevelRuntime.restore.',
      );
    }
    const keys = {
      'bodies',
      'active',
      'visible',
      'primitives',
      'motors',
      'vehicles',
      'controlled',
      'selection',
    };
    if (data.length != keys.length || !keys.containsAll(data.keys)) {
      throw const FormatException('Invalid native checkpoint.');
    }
    Map<String, Object?> map(Object? value) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('Expected native checkpoint object.');
      }
      return value;
    }

    Map<String, Map<String, Object?>> objects(
      Object? value,
      Iterable<String> expected,
    ) {
      final result = map(value), keys = expected.toSet();
      if (result.length != keys.length || !keys.containsAll(result.keys)) {
        throw const FormatException('Native checkpoint entity set differs.');
      }
      return {for (final e in result.entries) e.key: map(e.value)};
    }

    bool bounded(Object? value, double min, double max) =>
        value is num && value.isFinite && value >= min && value <= max;
    Vec3 vector(Object? value, double limit) {
      if (value is! List ||
          value.length != 3 ||
          !value.every((v) => bounded(v, -limit, limit))) {
        throw const FormatException('Invalid native checkpoint vector.');
      }
      return Vec3(
        (value[0] as num).toDouble(),
        (value[1] as num).toDouble(),
        (value[2] as num).toDouble(),
      );
    }

    final bodies = objects(data['bodies'], owner._bodies.keys);
    final sleeping = <String, bool>{};
    final poses = <String, PhysicsPose>{},
        velocities = <String, Vec3>{},
        angular = <String, Vec3>{};
    for (final e in bodies.entries) {
      if (!owner._bodies[e.key]!.isAlive ||
          e.value.length != 5 ||
          e.value['sleeping'] is! bool) {
        throw const FormatException('Checkpoint body is unavailable.');
      }
      sleeping[e.key] = e.value['sleeping'] as bool;
      final q = e.value['rotation'];
      if (q is! List || q.length != 4 || !q.every((v) => bounded(v, -1, 1))) {
        throw const FormatException('Invalid checkpoint rotation.');
      }
      final rotation = Quat(
        (q[0] as num).toDouble(),
        (q[1] as num).toDouble(),
        (q[2] as num).toDouble(),
        (q[3] as num).toDouble(),
      );
      final norm = q.fold<double>(
        0,
        (sum, v) => sum + (v as num).toDouble() * v.toDouble(),
      );
      if ((norm - 1).abs() > 1e-4) {
        throw const FormatException(
          'Checkpoint quaternion must be normalized.',
        );
      }
      poses[e.key] = PhysicsPose(
        position: vector(e.value['position'], 1e9),
        rotation: rotation,
      );
      velocities[e.key] = vector(e.value['velocity'], 1e6);
      angular[e.key] = vector(e.value['angular'], 1e6);
      if (owner._bodies[e.key]!.kind == BodyKind.fixed &&
          (velocities[e.key] != Vec3.zero || angular[e.key] != Vec3.zero)) {
        throw const FormatException(
          'Fixed body checkpoint cannot carry velocity.',
        );
      }
    }
    final active = map(data['active']);
    final ids = owner.project.levels
        .singleWhere((l) => l.id == session.levelId)
        .entities
        .map((e) => e.id)
        .toSet();
    if (active.length != ids.length ||
        !ids.containsAll(active.keys) ||
        active.values.any((v) => v is! bool)) {
      throw const FormatException('Invalid checkpoint active flags.');
    }
    final visible = map(data['visible']);
    if (visible.length != ids.length ||
        !ids.containsAll(visible.keys) ||
        visible.values.any((v) => v is! bool)) {
      throw const FormatException('Invalid checkpoint visibility.');
    }
    final primitives = objects(
      data['primitives'],
      owner._primitiveCharacters.keys.map((h) => h.id),
    );
    for (final value in primitives.values) {
      if (value.length != 2 ||
          !bounded(value['verticalSpeed'], -50, 50) ||
          value['grounded'] is! bool) {
        throw const FormatException('Invalid primitive character checkpoint.');
      }
    }
    final motors = objects(
      data['motors'],
      owner._characters.keys.map((h) => h.id),
    );
    for (final e in owner._characters.entries) {
      e.value.motor.validateState(motors[e.key.id]!);
    }
    final vehicles = objects(
      data['vehicles'],
      owner._vehicleControllers.keys.map((h) => h.id),
    );
    for (final e in owner._vehicleControllers.entries) {
      e.value.validateState(vehicles[e.key.id]!);
    }
    String? reference(Object? value) {
      if (value != null && (value is! String || !ids.contains(value))) {
        throw const FormatException(
          'Invalid native checkpoint entity reference.',
        );
      }
      return value as String?;
    }

    final controlled = reference(data['controlled']);
    if (controlled != null &&
        !{
          ...primitives.keys,
          ...motors.keys,
          ...vehicles.keys,
        }.contains(controlled)) {
      throw const FormatException(
        'Checkpoint controlled entity has no controller.',
      );
    }
    return _NativeLevelState(
      poses,
      velocities,
      angular,
      active.cast<String, bool>(),
      visible.cast<String, bool>(),
      sleeping,
      primitives,
      motors,
      vehicles,
      controlled,
      reference(data['selection']),
    );
  }

  @override
  void commit(GameSession session, _NativeLevelState prepared) {
    for (final e in prepared.poses.entries) {
      final body = owner._bodies[e.key]!;
      body.teleport(e.value);
      if (body.kind != BodyKind.fixed) {
        body.setVelocity(prepared.velocities[e.key]!);
        body.setAngularVelocity(prepared.angular[e.key]!);
        if (prepared.sleeping[e.key]!) {
          body.sleep();
        } else {
          body.wake();
        }
      }
      final authored = owner.project.levels
          .singleWhere((l) => l.id == session.levelId)
          .entities
          .singleWhere((r) => r.id == e.key);
      final object = owner.objects[authored.nodeId];
      if (object != null) {
        owner.simulation!.physics.unbind(object);
        owner.simulation!.physics.bind(object, body);
      }
    }
    for (final e in owner._characters.entries) {
      e.value.motor.restoreState(prepared.motors[e.key.id]!);
    }
    for (final e in owner._primitiveCharacters.entries) {
      e.value.verticalSpeed =
          (prepared.primitives[e.key.id]!['verticalSpeed'] as num).toDouble();
      e.value.grounded = prepared.primitives[e.key.id]!['grounded'] as bool;
    }
    for (final entity in session.entities.entities) {
      final authored = owner.project.levels
          .singleWhere((l) => l.id == session.levelId)
          .entities
          .singleWhere((r) => r.id == entity.handle.id);
      final object = owner.objects[authored.nodeId];
      if (object != null) {
        owner.setEntityActive(
          entity.handle,
          prepared.active[entity.handle.id]!,
        );
        object.visible = prepared.visible[entity.handle.id]!;
      }
    }
    owner._restoredNative = prepared;
  }
}
