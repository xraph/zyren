part of '../../runtime.dart';

/// Fresh host-built objects for one compiled recipe, with transferred resources.
final class GameRuntimeSpawnResources {
  final Map<String, Object3D> objects;
  final List<GameRuntimeResourceLease> resources;
  final Future<GameRuntimeResourceLease?> Function(List<ScenePlugin>)?
  attachPlugins;
  GameRuntimeSpawnResources({
    required Map<String, Object3D> objects,
    List<GameRuntimeResourceLease> resources = const [],
    this.attachPlugins,
  }) : objects = Map.unmodifiable(objects),
       resources = List.unmodifiable(resources);
}

final class GameRuntimeTopologyChange {
  final List<GameEntityHandle> added, removed;
  GameRuntimeTopologyChange({
    List<GameEntityHandle> added = const [],
    List<GameEntityHandle> removed = const [],
  }) : added = List.unmodifiable(added),
       removed = List.unmodifiable(removed);
}

/// A bounded native pool slot. Retirement keeps its scene/physics resources.
final class GameRuntimeSpawnInstance {
  final GameLevelRuntime _owner;
  final String id;
  final List<GameEntityRecord> records;
  final GameRuntimeSpawnResources _source;
  final _registrations = <void Function()>[];
  final _initialPoses = <String, PhysicsPose>{};
  final _initialMotors = <String, Map<String, Object?>>{};
  final _visible = <String, bool>{};
  final _handles = <GameEntityHandle>[];
  final _installedObjects = <String>{};
  GameRuntimeResourceLease? _pluginLease;
  Completer<bool>? _queued;
  GameEventSubscription? _queueState;
  bool _released = false;
  GameRuntimeSpawnInstance._(this._owner, this.id, this.records, this._source);
  List<GameEntityHandle> get handles => List.unmodifiable(_handles);
  bool get isActive =>
      !_released &&
      _handles.isNotEmpty &&
      _handles.every(
        (handle) => _owner.simulation?.session.entities.isAlive(handle) == true,
      );
  void _cancelQueued() {
    _queueState?.cancel();
    _queueState = null;
    final pending = _queued;
    _queued = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  Future<void> _closeResources() async {
    Object? first;
    StackTrace? trace;
    for (final resource in [?_pluginLease, ..._source.resources.reversed]) {
      try {
        await resource.close();
      } catch (error, stack) {
        first ??= error;
        trace ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, trace!);
  }
}

extension GameLevelRuntimeTopology on GameLevelRuntime {
  Registration registerSpawnValidator(
    void Function(List<GameEntityRecord>) validate,
  ) {
    if (_closed || _spawnValidators.length >= 64) {
      throw StateError('Spawn validation unavailable.');
    }
    _spawnValidators.add(validate);
    return Registration(() => _spawnValidators.remove(validate));
  }

  void _validateSpawn(List<GameEntityRecord> records) {
    final session = simulation!.session, epoch = simulation!.session.epoch;
    for (final validate in _spawnValidators.toList()) {
      if (_spawnValidators.contains(validate)) validate(records);
    }
    if (_closed ||
        error != null ||
        session.isClosed ||
        session.epoch != epoch) {
      throw StateError('Runtime changed during spawn validation.');
    }
  }

  Registration listenTopology(
    void Function(GameRuntimeTopologyChange) callback,
  ) {
    if (_closed || _topologyListeners.length >= 1024) {
      throw StateError('Topology listener unavailable.');
    }
    _topologyListeners.add(callback);
    return Registration(() => _topologyListeners.remove(callback));
  }

  GameSession _topologyBoundary() {
    final session = simulation?.session;
    if (_closed ||
        error != null ||
        !_setupReady ||
        _restoringCheckpoint ||
        session == null ||
        session.isStepping ||
        session.isRestoring) {
      throw StateError(
        'Native topology requires a healthy initialized runtime.',
      );
    }
    return session;
  }

  Future<GameRuntimeSpawnInstance> prepareSpawn(
    GameSpawnTemplate template, {
    required String instanceId,
    required Future<GameRuntimeSpawnResources> Function(List<GameEntityRecord>)
    prepare,
  }) {
    final session = _topologyBoundary();
    if (_spawnSlots.containsKey(instanceId) ||
        _preparingSpawnIds.contains(instanceId) ||
        _spawnSlots.length + _preparingSpawnIds.length >= maxPreparedSpawns ||
        template.entities.isEmpty ||
        template.entities.length > 32) {
      throw StateError(
        'Native spawn identity or bounded pool capacity is unavailable.',
      );
    }
    final records = template
        .instantiate(instanceId)
        .map(
          (record) => GameEntityRecord(
            id: record.id,
            nodeId: record.nodeId == null
                ? null
                : '${Uri.encodeComponent(instanceId)}/${Uri.encodeComponent(record.nodeId!)}',
            components: record.components,
          ),
        )
        .toList(growable: false);
    if (records.map((r) => r.nodeId).toSet().length != records.length) {
      throw StateError('Spawn entities require distinct scene nodes.');
    }
    for (final record in records) {
      if (_records.containsKey(record.id) ||
          record.nodeId == null ||
          record.components.any(
            (c) => c.type == 'game.input' || c.type == 'game.camera',
          ) ||
          record.components.any(
            (c) => c.required && !project.project.registry.supports(c),
          )) {
        throw StateError(
          'Spawn recipe requires fresh nodes and available NPC components.',
        );
      }
      for (final component in record.components) {
        project.project.registry.normalize(component);
      }
    }
    _validateSpawn(List.unmodifiable(records));
    _preparingSpawnIds.add(instanceId);
    late Future<GameRuntimeSpawnInstance> operation;
    operation = _prepareSpawn(
      instanceId,
      List.unmodifiable(records),
      prepare,
      session.epoch,
    );
    _spawnPreparations.add(operation);
    operation.then<void>(
      (_) {
        _spawnPreparations.remove(operation);
        _preparingSpawnIds.remove(instanceId);
      },
      onError: (Object _, StackTrace _) {
        _spawnPreparations.remove(operation);
        _preparingSpawnIds.remove(instanceId);
      },
    );
    return operation;
  }

  Future<GameRuntimeSpawnInstance> _prepareSpawn(
    String id,
    List<GameEntityRecord> records,
    Future<GameRuntimeSpawnResources> Function(List<GameEntityRecord>) prepare,
    int epoch,
  ) async {
    final source = await prepare(records);
    final slot = GameRuntimeSpawnInstance._(this, id, records, source);
    var adopted = false;
    try {
      if (source.resources.length > 64 ||
          source.objects.length > 128 ||
          source.resources.toSet().length != source.resources.length ||
          source.resources.any((r) => r._owner != null || r._closing != null)) {
        throw ArgumentError('Spawn resource leases must be fresh and bounded.');
      }
      for (final resource in source.resources) {
        resource._owner = this;
      }
      adopted = true;
      if (_closed || simulation!.session.epoch != epoch) {
        throw StateError('Runtime changed during native spawn preparation.');
      }
      _topologyBoundary();
      final objects = source.objects.values.toSet();
      if (objects.length != source.objects.length ||
          records.any((r) => !source.objects.containsKey(r.nodeId)) ||
          source.objects.keys.any((key) => _objects.containsKey(key)) ||
          objects.any(
            (object) =>
                _objects.containsValue(object) ||
                object.parent != null && !objects.contains(object.parent),
          )) {
        throw ArgumentError(
          'Spawn scene nodes must be fresh and self-contained.',
        );
      }
      for (final entry in source.objects.entries) {
        GameEntityRecord(id: entry.key); // Reuse core identifier validation.
        _objects[entry.key] = entry.value;
        slot._installedObjects.add(entry.key);
        if (entry.value.parent == null) scene.add(entry.value);
      }
      for (final record in records) {
        _records[record.id] = record;
        _recordSlots[record.id] = slot;
        slot._visible[record.id] = _objects[record.nodeId]!.visible;
        _createNativeEntity(record);
        final body = _bodies[record.id];
        if (body != null) {
          slot._initialPoses[record.id] = body.state.pose;
          _setPooledActive(record, false);
          if (body.kind == BodyKind.dynamic) body.sleep();
        }
        _objects[record.nodeId]!.visible = false;
      }
      final plugins = <ScenePlugin>[
        for (final record in records) ...?_animations[record.id]?.plugins,
      ];
      if (plugins.isNotEmpty) {
        if (source.attachPlugins == null) {
          throw StateError('Imported spawn rigs require host plugin adoption.');
        }
        final pluginLease = await source.attachPlugins!(
          List.unmodifiable(plugins),
        );
        if (pluginLease == null ||
            pluginLease._owner != null ||
            pluginLease._closing != null) {
          throw StateError('Host must return a fresh plugin release lease.');
        }
        slot._pluginLease = pluginLease;
        pluginLease._owner = this;
      }
      if (_closed || simulation!.session.epoch != epoch) {
        throw StateError('Runtime changed during native plugin adoption.');
      }
      for (final record in records) {
        if (_animations[record.id] case final animation?) {
          slot._initialMotors[record.id] = animation.motor.captureState();
        }
      }
      for (final resource in source.resources) {
        resource.pause();
      }
      slot._pluginLease?.pause();
      _spawnSlots[id] = slot;
      return slot;
    } catch (error, stack) {
      try {
        await slot._pluginLease?.close();
      } catch (_) {}
      _removeSpawnNative(slot);
      if (adopted) {
        try {
          await slot._closeResources();
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _setPooledActive(GameEntityRecord record, bool active) {
    final data = record.components
        .where((c) => c.type == 'game.collider')
        .firstOrNull;
    if (data != null && _colliders[record.id] != null) {
      final definition = GameColliderDefinition.fromJson(data.data);
      _colliders[record.id]!.configure(
        density: 0,
        friction: definition.friction,
        restitution: definition.restitution,
        sensor: active ? definition.sensor : true,
        membership: active ? 0xffffffff : 0,
        filter: active ? 0xffffffff : 0,
      );
    }
    _active[record.id] = active;
  }

  void _registerActor(String id, void Function() callback) {
    _actorRegistrations.add(callback);
    _recordSlots[id]?._registrations.add(callback);
  }

  void _faultTopology(Object error) {
    _checkpointFault = error;
    simulation!.session.invalidatePending();
    simulation!.physics.paused = true;
    try {
      simulation!.session.pause();
    } catch (_) {}
  }

  void _notifyTopology(GameRuntimeTopologyChange change) {
    try {
      for (final callback in _topologyListeners.toList()) {
        if (_topologyListeners.contains(callback)) callback(change);
      }
      _publish();
    } catch (error) {
      _faultTopology(error);
      rethrow;
    }
  }

  void activateSpawn(GameRuntimeSpawnInstance slot) {
    if (!_topologyBoundary().paused) {
      throw StateError('Use queued spawn during running play.');
    }
    _activateSpawn(slot);
  }

  void _checkSlot(GameRuntimeSpawnInstance slot) {
    if (_closed ||
        error != null ||
        !identical(slot._owner, this) ||
        slot._released ||
        !identical(_spawnSlots[slot.id], slot)) {
      throw StateError('Spawn slot is unavailable.');
    }
  }

  void _activateSpawn(GameRuntimeSpawnInstance slot) {
    _checkSlot(slot);
    final session = simulation!.session;
    if (slot._handles.isNotEmpty ||
        session.entities.length + slot.records.length >
            session.entities.limits.maxEntities) {
      throw StateError('Spawn slot is active or entity capacity is exhausted.');
    }
    _validateSpawn(slot.records);
    final setup = _PlaySetup(this);
    try {
      for (final record in slot.records) {
        final handle = session.entities.spawn(
          record.id,
          components: record.components,
        );
        slot._handles.add(handle);
        final body = _bodies[record.id];
        body?.teleport(slot._initialPoses[record.id]!);
        body?.wake();
        _animations[record.id]?.motor.restoreState(
          slot._initialMotors[record.id]!,
        );
        _setPooledActive(record, true);
        _objects[record.nodeId]!.visible = slot._visible[record.id]!;
        setup.bindController(
          session,
          record,
          handle,
          (callback) => _registerActor(record.id, callback),
        );
        if (body != null &&
            !_animations.containsKey(record.id) &&
            !record.components.any((c) => c.type == 'game.vehicle')) {
          simulation!.physics.bind(_objects[record.nodeId]!, body);
          _registerActor(
            record.id,
            () => simulation!.physics.unbind(_objects[record.nodeId]!),
          );
        }
        if (_characters.containsKey(handle) ||
            _primitiveCharacters.containsKey(handle) ||
            _vehicleControllers.containsKey(handle)) {
          setup.bindSeat(
            session,
            handle,
            (callback) => _registerActor(record.id, callback),
          );
        }
      }
      world!.rayCast(
        origin: Vec3.zero,
        direction: const Vec3(0, 1, 0),
        maxDistance: .001,
      );
    } catch (_) {
      _retireSpawn(slot, notify: false);
      rethrow;
    }
    try {
      for (final resource in slot._source.resources) {
        if (session.paused) {
          resource.pause();
        } else {
          resource.resume();
        }
      }
      if (session.paused) {
        slot._pluginLease?.pause();
      } else {
        slot._pluginLease?.resume();
      }
      _notifyTopology(GameRuntimeTopologyChange(added: slot.handles));
    } catch (error) {
      _faultTopology(error);
      rethrow;
    }
  }

  void retireSpawn(GameRuntimeSpawnInstance slot) {
    if (!_topologyBoundary().paused) {
      throw StateError('Use queued despawn during running play.');
    }
    _retireSpawn(slot);
  }

  void _retireSpawn(GameRuntimeSpawnInstance slot, {bool notify = true}) {
    _checkSlot(slot);
    final removed = slot.handles;
    for (final handle in removed) {
      _actorControls[handle]?.dispose();
      _characters.remove(handle);
      _primitiveCharacters.remove(handle);
      _primitiveIntents.remove(handle);
      _vehicleControllers.remove(handle);
      _characterLeases.remove(handle)?.dispose();
      _vehicleLeases.remove(handle)?.dispose();
    }
    for (final callback in slot._registrations.reversed) {
      _actorRegistrations.remove(callback);
      callback();
    }
    slot._registrations.clear();
    for (final handle in removed) {
      simulation!.session.entities.despawn(handle);
    }
    slot._handles.clear();
    if (removed.contains(_controlled)) {
      _controlled = null;
      for (final rig in _cameras) {
        rig.follow(null);
      }
    }
    if (removed.contains(_selection)) _selection = null;
    for (final record in slot.records) {
      _setPooledActive(record, false);
      _objects[record.nodeId]!.visible = false;
      final body = _bodies[record.id];
      if (body?.kind == BodyKind.dynamic) body!.sleep();
    }
    try {
      for (final resource in slot._source.resources) {
        resource.pause();
      }
      slot._pluginLease?.pause();
      if (removed.isNotEmpty && notify) {
        _notifyTopology(GameRuntimeTopologyChange(removed: removed));
      }
    } catch (error) {
      _faultTopology(error);
      rethrow;
    }
  }

  Future<bool> enqueueSpawn(GameRuntimeSpawnInstance slot) =>
      _queueSpawn(slot, true);
  Future<bool> enqueueDespawn(GameRuntimeSpawnInstance slot) =>
      _queueSpawn(slot, false);
  Future<bool> _queueSpawn(GameRuntimeSpawnInstance slot, bool activate) {
    final session = _topologyBoundary();
    _checkSlot(slot);
    if (session.paused || slot._queued != null) {
      throw StateError('Topology queue is unavailable.');
    }
    final result = Completer<bool>(), epoch = session.epoch;
    slot._queued = result;
    slot._queueState = session.listenState(() {
      if (session.epoch != epoch || session.isClosed) slot._cancelQueued();
    });
    try {
      session.enqueueMutation((_) {
        if (!identical(slot._queued, result) ||
            session.epoch != epoch ||
            slot._released) {
          if (!result.isCompleted) result.complete(false);
          return;
        }
        slot._queueState?.cancel();
        slot._queueState = null;
        slot._queued = null;
        try {
          if (activate) {
            _activateSpawn(slot);
          } else {
            _retireSpawn(slot);
          }
          result.complete(true);
        } catch (error, stack) {
          result.completeError(error, stack);
          rethrow;
        }
      });
    } catch (_) {
      slot._cancelQueued();
      rethrow;
    }
    return result.future;
  }

  Future<void> releaseSpawn(GameRuntimeSpawnInstance slot) async {
    if (!_topologyBoundary().paused) {
      throw StateError('Pause before releasing native pool resources.');
    }
    _checkSlot(slot);
    if (slot._handles.isNotEmpty || slot._queued != null) {
      throw StateError('Retire the slot first.');
    }
    await slot._pluginLease?.close();
    _removeSpawnNative(slot);
    await slot._closeResources();
  }

  void _removeSpawnNative(GameRuntimeSpawnInstance slot) {
    for (final record in slot.records) {
      if (!identical(_recordSlots[record.id], slot)) continue;
      final root = _objects[record.nodeId];
      if (root != null) simulation?.physics.unbind(root);
      final body = _bodies.remove(record.id);
      if (body?.isAlive == true) body!.remove();
      _colliders.remove(record.id);
      _shapes.remove(record.id);
      _animations.remove(record.id);
      _active.remove(record.id);
      _records.remove(record.id);
      _recordSlots.remove(record.id);
    }
    for (final entry in slot._source.objects.entries) {
      if (slot._installedObjects.contains(entry.key) &&
          identical(_objects[entry.key], entry.value)) {
        entry.value.parent?.remove(entry.value);
        _objects.remove(entry.key);
      }
    }
    _spawnSlots.remove(slot.id);
    slot._released = true;
  }
}
