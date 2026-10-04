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
  final core = session.save();
  final save = GameSave(
    projectId: core.projectId,
    buildId: core.buildId,
    levelId: core.levelId,
    projectSchema: core.projectSchema,
    seed: core.seed,
    tick: core.tick,
    paused: core.paused,
    models: core.models,
    state: core.state,
    codecVersions: core.codecVersions,
    entities: [
      for (final e in core.entities)
        GameEntityRecord(
          id: e.id,
          nodeId: owner._records[e.id]?.nodeId,
          components: e.components,
        ),
    ],
  );
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
  if (records.length != save.entities.length ||
      records.keys.any((id) => !owner._records.containsKey(id)) ||
      !records.keys.toSet().containsAll(authored.map((e) => e.id)) ||
      records.keys
          .map((id) => owner._records[id]!)
          .any(
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
  for (final slot in owner._spawnSlots.values) {
    final count = slot.records.where((e) => records.containsKey(e.id)).length;
    if (count != 0 && count != slot.records.length) {
      throw const FormatException(
        'Checkpoint contains a partial spawn recipe.',
      );
    }
  }
  final native = save.state['game.native-level'];
  if (native is! Map ||
      native['active'] is! Map ||
      (native['active'] as Map).length != records.length ||
      !records.keys.toSet().containsAll((native['active'] as Map).keys)) {
    throw const FormatException('Native state and logical entities differ.');
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
    owner._releaseActorControls();
    for (final input in owner._inputs.values) {
      input.releaseEveryDevice();
    }
    for (final registration in owner._actorRegistrations.reversed) {
      registration();
    }
    owner._actorRegistrations.clear();
    for (final slot in owner._spawnSlots.values) {
      slot._cancelQueued();
      slot._registrations.clear();
      slot._handles.clear();
      slot._handles.addAll(
        session.entities.entities
            .where((e) => slot.records.any((r) => r.id == e.handle.id))
            .map((e) => e.handle),
      );
    }
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
    for (final slot in owner._spawnSlots.values.where((s) => s.isActive)) {
      for (final record in slot.records) {
        if (owner._bodies[record.id] case final body?) {
          if (!owner._animations.containsKey(record.id) &&
              !record.components.any((c) => c.type == 'game.vehicle')) {
            final object = owner._objects[record.nodeId]!;
            owner.simulation!.physics.unbind(object);
            owner.simulation!.physics.bind(object, body);
            owner._registerActor(
              record.id,
              () => owner.simulation!.physics.unbind(object),
            );
          }
        }
      }
    }
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
    if (!session.paused && owner._controlled != null) owner._restoreControl();
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
    for (final slot in owner._spawnSlots.values) {
      for (final resource in [...slot._source.resources, ?slot._pluginLease]) {
        if (session.paused || !slot.isActive) {
          resource.pause();
        } else {
          resource.resume();
        }
      }
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
        if (session.entities.entities.any(
          (entity) => entity.handle.id == e.key,
        ))
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
      for (final entity in session.entities.entities)
        for (final e in [owner._records[entity.handle.id]!])
          e.id: owner._active[e.id] ?? true,
    },
    'visible': {
      for (final entity in session.entities.entities)
        for (final e in [owner._records[entity.handle.id]!])
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

    final active = map(data['active']);
    final ids = active.keys.toSet();
    if (ids.any((id) => !owner._records.containsKey(id))) {
      throw const FormatException('Unknown prepared checkpoint recipe.');
    }
    Iterable<String> withComponent(String type) => ids.where(
      (id) => owner._records[id]!.components.any((c) => c.type == type),
    );
    final bodies = objects(
      data['bodies'],
      ids.where(owner._bodies.containsKey),
    );
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
      withComponent(
        'game.character',
      ).where((id) => !owner._animations.containsKey(id)),
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
      withComponent('game.character').where(owner._animations.containsKey),
    );
    for (final e in motors.entries) {
      owner._animations[e.key]!.motor.validateState(e.value);
    }
    final vehicles = objects(data['vehicles'], withComponent('game.vehicle'));
    for (final e in vehicles.entries) {
      VehicleController.validateCheckpoint(
        VehicleDefinition.fromJson(
          owner._records[e.key]!.components
              .singleWhere((c) => c.type == 'game.vehicle')
              .data,
        ),
        e.value,
      );
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
    for (final slot in owner._spawnSlots.values) {
      for (final record in slot.records.where(
        (r) => !prepared.active.containsKey(r.id),
      )) {
        owner._setPooledActive(record, false);
        final object = owner._objects[record.nodeId]!;
        object.visible = false;
        if (!owner._animations.containsKey(record.id) &&
            !record.components.any((c) => c.type == 'game.vehicle')) {
          owner.simulation!.physics.unbind(object);
        }
        final body = owner._bodies[record.id];
        if (body?.kind == BodyKind.dynamic) {
          body!.sleep();
        }
      }
    }
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
      final authored = owner._records[e.key]!;
      final object = owner.objects[authored.nodeId];
      if (object != null &&
          !owner._animations.containsKey(e.key) &&
          !authored.components.any((c) => c.type == 'game.vehicle')) {
        owner.simulation!.physics.unbind(object);
        owner.simulation!.physics.bind(object, body);
      }
    }
    for (final e in prepared.motors.entries) {
      owner._animations[e.key]!.motor.restoreState(e.value);
    }
    for (final e in owner._primitiveCharacters.entries) {
      if (!prepared.primitives.containsKey(e.key.id)) continue;
      e.value.verticalSpeed =
          (prepared.primitives[e.key.id]!['verticalSpeed'] as num).toDouble();
      e.value.grounded = prepared.primitives[e.key.id]!['grounded'] as bool;
    }
    for (final entity in session.entities.entities) {
      final authored = owner._records[entity.handle.id]!;
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
