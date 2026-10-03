part of '../authoring.dart';

final class GameAuthoring {
  final GameRegistry registry;
  final Map<String, GameComponentDescriptor> descriptors;
  late final GameDocumentCodec codec = GameDocumentCodec(registry);
  GameAuthoring(
    GameRegistry registry, {
    Iterable<GameComponentDescriptor> descriptors = const [],
  }) : registry = registry.snapshot(),
       descriptors = Map.unmodifiable({for (final d in descriptors) d.type: d});

  StudioDocument initialize(
    StudioDocument document, {
    String? projectId,
    String? levelId,
  }) {
    if (document.extensions.containsKey(codec.namespace)) return document;
    return document.copyWith(
      extensions: {
        ...document.extensions,
        codec.namespace: codec.write(
          GameDocumentData(
            projectId: projectId ?? document.id,
            levelId: levelId ?? document.id,
            entities: [],
          ),
        ),
      },
    );
  }

  GameDocumentData _local(StudioDocument document) => codec.read(
    initialize(document).extensions[codec.namespace]!,
    validateComponents: false,
  );
  GameDocumentData expanded(StudioDocument document) =>
      codec.expand(initialize(document));
  GameEntityRecord? entityFor(StudioDocument document, String nodeId) {
    if (!document.prefabOwners.containsKey(nodeId)) {
      return _local(
        document,
      ).entities.where((e) => e.nodeId == nodeId).firstOrNull;
    }
    return expanded(
      document,
    ).entities.where((e) => e.nodeId == nodeId).firstOrNull;
  }

  List<GameEntityRecord> editableEntities(StudioDocument document) {
    try {
      return expanded(document).entities;
    } catch (_) {
      return _local(document).entities;
    }
  }

  StudioDocument _write(StudioDocument document, GameDocumentData data) =>
      document.copyWith(
        extensions: {
          ...document.extensions,
          codec.namespace: codec.write(data),
        },
      );
  StudioDocument _checked(StudioDocument document) {
    final errors = validate(document).where((i) => i.blocksEdit).toList();
    if (errors.isNotEmpty) throw GameAuthoringException(errors);
    return document;
  }

  StudioDocument _replace(
    StudioDocument document,
    List<GameEntityRecord> entities,
  ) {
    final data = _local(document);
    return _checked(
      _write(
        document,
        GameDocumentData(
          projectId: data.projectId,
          levelId: data.levelId,
          entities: entities,
        ),
      ),
    );
  }

  StudioDocument addComponent(
    StudioDocument document,
    String nodeId,
    GameComponentRecord component,
  ) {
    if (!document.expandedNodes.containsKey(nodeId)) {
      throw ArgumentError('Unknown game node.');
    }
    if (document.prefabOwners.containsKey(nodeId)) {
      throw StateError('Add components to the prefab definition.');
    }
    final data = _local(document);
    final existing = data.entities.where((e) => e.nodeId == nodeId).firstOrNull;
    if (existing?.components.any((c) => c.type == component.type) ?? false) {
      throw StateError('Component already exists.');
    }
    final normalized = registry.normalize(component);
    if (!registry.supports(normalized)) {
      throw StateError('Component codec is unavailable.');
    }
    final entity = GameEntityRecord(
      id: existing?.id ?? nodeId,
      nodeId: nodeId,
      components: [...?existing?.components, normalized],
    );
    return _replace(document, [
      ...data.entities.where((e) => e.id != entity.id),
      entity,
    ]);
  }

  StudioDocument removeComponent(
    StudioDocument document, {
    required String nodeId,
    required String component,
  }) {
    if (document.prefabOwners.containsKey(nodeId)) {
      throw StateError('Remove components from the prefab definition.');
    }
    final data = _local(document);
    final entity = data.entities.singleWhere((e) => e.nodeId == nodeId);
    if (!entity.components.any((c) => c.type == component)) {
      throw ArgumentError('Unknown component.');
    }
    return _replace(
      document,
      data.entities
          .map(
            (e) => e.id != entity.id
                ? e
                : GameEntityRecord(
                    id: e.id,
                    nodeId: e.nodeId,
                    components: e.components
                        .where((c) => c.type != component)
                        .toList(),
                  ),
          )
          .toList(),
    );
  }

  StudioDocument setField(
    StudioDocument document, {
    required String nodeId,
    required String component,
    required String field,
    required Object? value,
  }) => setFields(
    document,
    nodeId: nodeId,
    component: component,
    fields: {field: value},
  );
  StudioDocument setFields(
    StudioDocument document, {
    required String nodeId,
    required String component,
    required Map<String, Object?> fields,
  }) {
    final owner = document.prefabOwners[nodeId];
    if (owner != null) {
      return overridePrefabComponent(
        document,
        instanceId: owner,
        nodePath: nodeId.substring(owner.length + 1),
        component: component,
        fields: fields,
      );
    }
    final data = _local(document);
    final entity = data.entities.singleWhere((e) => e.nodeId == nodeId);
    final source = entity.components.singleWhere((c) => c.type == component);
    _validateFields(nodeId, source, fields);
    final next = registry.normalize(
      GameComponentRecord(source.type, source.version, {
        ...source.data,
        ...fields,
      }, required: source.required),
    );
    return _replace(
      document,
      data.entities
          .map(
            (e) => e.id != entity.id
                ? e
                : GameEntityRecord(
                    id: e.id,
                    nodeId: e.nodeId,
                    components: e.components
                        .map((c) => c.type == component ? next : c)
                        .toList(),
                  ),
          )
          .toList(),
    );
  }

  void _validateFields(
    String nodeId,
    GameComponentRecord component,
    Map<String, Object?> fields,
  ) {
    final descriptor = descriptors[component.type];
    if (descriptor == null) return;
    for (final entry in fields.entries) {
      final field = descriptor.fields
          .where((f) => f.name == entry.key)
          .firstOrNull;
      final error = field == null
          ? 'Unknown component field ${entry.key}.'
          : field.validate(entry.value);
      if (error != null) {
        throw GameAuthoringException([
          GameAuthoringIssue(
            error,
            nodeId: nodeId,
            component: component.type,
            field: entry.key,
          ),
        ]);
      }
    }
  }

  StudioDocument overridePrefabComponent(
    StudioDocument document, {
    required String instanceId,
    required String nodePath,
    required String component,
    required Map<String, Object?> fields,
  }) {
    final instance = document.nodes.singleWhere((n) => n.id == instanceId);
    if (instance.kind != StudioNodeKind.prefab) {
      throw ArgumentError('Expected prefab instance.');
    }
    final entity = entityFor(document, '$instanceId/$nodePath');
    if (entity == null) {
      throw ArgumentError('Prefab component entity is missing.');
    }
    final source = entity.components.singleWhere((c) => c.type == component);
    _validateFields('$instanceId/$nodePath', source, fields);
    // Runtime IDs escape path segments; overrides use local expanded entity IDs.
    final local = codec.expand(
      initialize(
        StudioDocument(
          id: document.id,
          title: document.title,
          nodes: document.prefabs
              .singleWhere((p) => p.id == instance.prefabId)
              .nodes,
          assets: document.assets,
          prefabs: document.prefabs,
          extensions: document.prefabs
              .singleWhere((p) => p.id == instance.prefabId)
              .extensions,
        ),
        projectId: _local(document).projectId,
        levelId: _local(document).levelId,
      ),
    );
    final localId = local.entities.singleWhere((e) => e.nodeId == nodePath).id;
    final payload =
        jsonDecode(
              jsonEncode(
                instance.extensionOverrides[codec.namespace] ??
                    {'entities': {}},
              ),
            )
            as Map<String, dynamic>;
    final entities = payload['entities'] as Map<String, dynamic>;
    final edits =
        entities.putIfAbsent(localId, () => {'components': <String, dynamic>{}})
            as Map<String, dynamic>;
    final components = edits['components'] as Map<String, dynamic>;
    components[component] = {
      ...?components[component] as Map<String, dynamic>?,
      ...fields,
    };
    return _checked(
      document.copyWith(
        nodes: document.nodes.map(
          (n) => n.id == instanceId
              ? n.copyWith(
                  extensionOverrides: {
                    ...n.extensionOverrides,
                    codec.namespace: payload,
                  },
                )
              : n,
        ),
      ),
    );
  }

  StudioDocument resetPrefabFields(
    StudioDocument document, {
    required String instanceId,
    required String entityId,
    required String component,
    required Set<String> fields,
  }) {
    final instance = document.nodes.singleWhere((n) => n.id == instanceId);
    final payload =
        jsonDecode(
              jsonEncode(
                instance.extensionOverrides[codec.namespace] ??
                    {'entities': {}},
              ),
            )
            as Map<String, dynamic>;
    final edits =
        (payload['entities'] as Map<String, dynamic>)[entityId]
            as Map<String, dynamic>?;
    final components = edits?['components'] as Map<String, dynamic>?;
    final values = components?[component] as Map<String, dynamic>?;
    if (values == null) return document;
    values.removeWhere((k, _) => fields.contains(k));
    if (values.isEmpty) components!.remove(component);
    if (components!.isEmpty) (payload['entities'] as Map).remove(entityId);
    return _checked(
      document.copyWith(
        nodes: document.nodes.map(
          (n) => n.id == instanceId
              ? n.copyWith(
                  extensionOverrides: {
                    ...n.extensionOverrides,
                    codec.namespace: payload,
                  },
                )
              : n,
        ),
      ),
    );
  }

  GameFieldOrigin fieldOrigin(
    StudioDocument document, {
    required String nodeId,
    required String component,
    required String field,
  }) {
    final entity = entityFor(document, nodeId);
    final value = entity?.components
        .where((c) => c.type == component)
        .firstOrNull;
    if (value == null || !value.data.containsKey(field)) {
      return GameFieldOrigin.missing;
    }
    final owner = document.prefabOwners[nodeId];
    if (owner == null) return GameFieldOrigin.authored;
    final instance = document.nodes.singleWhere((n) => n.id == owner);
    final prefix = '${Uri.encodeComponent(owner)}/';
    final localId = entity!.id.startsWith(prefix)
        ? Uri.decodeComponent(entity.id.substring(prefix.length))
        : entity.id;
    final entities = instance.extensionOverrides[codec.namespace]?['entities'];
    final edits = entities is Map ? entities[localId] : null;
    final components = edits is Map ? edits['components'] : null;
    final fields = components is Map ? components[component] : null;
    return fields is Map && fields.containsKey(field)
        ? GameFieldOrigin.overridden
        : GameFieldOrigin.inherited;
  }

  StudioDocument createPrefab(
    StudioDocument document,
    String nodeId, {
    required String prefabId,
  }) {
    final data = _local(document);
    final selected = <String>{nodeId};
    bool changed;
    do {
      changed = false;
      for (final node in document.nodes) {
        if (selected.contains(node.parentId) && selected.add(node.id)) {
          changed = true;
        }
      }
    } while (changed);
    final own = data.entities
        .where((e) => selected.contains(e.nodeId))
        .toList();
    final ownIds = own.map((e) => e.id).toSet();
    for (final entity in own) {
      for (final component in entity.components) {
        if (registry
            .references(component)
            .any((r) => !ownIds.contains(r.targetId))) {
          throw StateError(
            'A prefab definition must keep its component references inside the selection.',
          );
        }
      }
    }
    final withoutGame = document.copyWith(
      extensions: {...document.extensions}..remove(codec.namespace),
    );
    final next = StudioAuthoring.createPrefab(
      withoutGame,
      nodeId,
      prefabId: prefabId,
    );
    final remappedIds = {
      for (final entity in own)
        entity.id:
            '${Uri.encodeComponent(nodeId)}/${Uri.encodeComponent(entity.id)}',
    };
    final remaining = data.entities
        .where((e) => !ownIds.contains(e.id))
        .map((e) => _remapEntity(e, e.id, e.nodeId, remappedIds))
        .toList();
    final withPrefab = next.copyWith(
      prefabs: next.prefabs.map(
        (p) => p.id != prefabId
            ? p
            : p.copyWith(
                extensions: {
                  ...p.extensions,
                  codec.namespace: codec.write(
                    GameDocumentData(
                      projectId: data.projectId,
                      levelId: data.levelId,
                      entities: own,
                    ),
                  ),
                },
              ),
      ),
    );
    return _checked(
      _write(
        withPrefab,
        GameDocumentData(
          projectId: data.projectId,
          levelId: data.levelId,
          entities: remaining,
        ),
      ),
    );
  }

  StudioDocument duplicate(
    StudioDocument document,
    String nodeId, {
    required String newId,
  }) {
    if (document.prefabOwners.containsKey(nodeId)) {
      throw StateError('Duplicate the prefab instance.');
    }
    if (document.expandedNodes.containsKey(newId)) {
      throw ArgumentError('Duplicate node identity.');
    }
    if (document.extensions.keys.any((k) => k != codec.namespace)) {
      throw StateError(
        'Duplicate with the owning extension when other document payloads are present.',
      );
    }
    final root = document.nodes.singleWhere((n) => n.id == nodeId);
    final ids = <String, String>{nodeId: newId};
    bool changed;
    do {
      changed = false;
      for (final node in document.nodes) {
        if (ids.containsKey(node.parentId) && !ids.containsKey(node.id)) {
          ids[node.id] = '$newId/${Uri.encodeComponent(node.id)}';
          changed = true;
        }
      }
    } while (changed);
    final data = _local(document);
    final selected = data.entities
        .where((e) => ids.containsKey(e.nodeId))
        .toList();
    final entityIds = {
      for (final e in selected)
        e.id: e.id == e.nodeId
            ? ids[e.nodeId]!
            : '${Uri.encodeComponent(ids[e.nodeId]!)}/${Uri.encodeComponent(e.id)}',
    };
    final entities = [
      ...data.entities,
      for (final e in selected)
        _remapEntity(e, entityIds[e.id]!, ids[e.nodeId], entityIds),
    ];
    final next = document.copyWith(
      nodes: [
        ...document.nodes,
        for (final node in document.nodes.where((n) => ids.containsKey(n.id)))
          node.copyWith(
            id: ids[node.id],
            parentId: node == root ? root.parentId : ids[node.parentId],
            clearParent: node == root && root.parentId == null,
          ),
      ],
    );
    return _replace(next, entities);
  }

  GameEntityRecord _remapEntity(
    GameEntityRecord entity,
    String id,
    String? nodeId,
    Map<String, String> ids,
  ) => GameEntityRecord(
    id: id,
    nodeId: nodeId,
    components: entity.components.map((component) {
      if (!registry.supports(component)) {
        throw StateError('Load component codecs before remapping references.');
      }
      final data =
          jsonDecode(jsonEncode(component.data)) as Map<String, dynamic>;
      for (final reference in registry.references(component)) {
        dynamic value = data;
        for (final segment in reference.path.take(reference.path.length - 1)) {
          value = value[segment];
        }
        value[reference.path.last] =
            ids[reference.targetId] ?? reference.targetId;
      }
      return GameComponentRecord(
        component.type,
        component.version,
        data,
        required: component.required,
      );
    }).toList(),
  );

  StudioDocument repair(StudioDocument document, GameRepairCommand command) =>
      switch (command.kind) {
        GameRepairKind.removeComponent => removeComponent(
          document,
          nodeId: command.nodeId,
          component: command.component,
        ),
        GameRepairKind.addDependency => addComponent(
          document,
          command.nodeId,
          (descriptors[command.component] ??
                  (throw StateError('Dependency descriptor is unavailable.')))
              .create(),
        ),
        GameRepairKind.selectTarget => throw StateError(
          'Choose a target entity in the inspector.',
        ),
      };

  List<GameAuthoringIssue> validate(StudioDocument document) {
    final issues = <GameAuthoringIssue>[];
    GameDocumentData data;
    Object? expansionError;
    try {
      data = expanded(document);
    } catch (error) {
      expansionError = error;
      try {
        data = _local(document);
      } catch (_) {
        return [GameAuthoringIssue(error.toString())];
      }
    }
    for (final entity in data.entities) {
      for (final component in entity.components) {
        final descriptor = descriptors[component.type];
        if (!registry.supports(component)) {
          issues.add(
            GameAuthoringIssue(
              'Component codec ${component.type}@${component.version} is unavailable.',
              nodeId: entity.nodeId,
              component: component.type,
              blocksEdit: false,
              blocksPlay: component.required,
            ),
          );
          continue;
        }
        var validData = true;
        try {
          registry.normalize(component);
        } catch (error) {
          validData = false;
          issues.add(
            GameAuthoringIssue(
              error.toString(),
              nodeId: entity.nodeId,
              component: component.type,
              repair: entity.nodeId == null
                  ? null
                  : GameRepairCommand(
                      GameRepairKind.removeComponent,
                      entity.nodeId!,
                      component.type,
                    ),
            ),
          );
        }
        if (validData && document.prefabs.isEmpty) {
          for (final reference in registry.references(component)) {
            if (!data.entities.any((e) => e.id == reference.targetId)) {
              issues.add(
                GameAuthoringIssue(
                  'Target ${reference.targetId} is missing.',
                  nodeId: entity.nodeId,
                  component: component.type,
                  field: reference.path.join('.'),
                  repair: entity.nodeId == null
                      ? null
                      : GameRepairCommand(
                          GameRepairKind.selectTarget,
                          entity.nodeId!,
                          component.type,
                          field: reference.path.join('.'),
                        ),
                ),
              );
            }
          }
        }
        for (final dependency in descriptor?.dependencies ?? <String>{}) {
          if (!entity.components.any((c) => c.type == dependency)) {
            issues.add(
              GameAuthoringIssue(
                '${component.type} requires $dependency.',
                nodeId: entity.nodeId,
                component: component.type,
                repair: entity.nodeId == null
                    ? null
                    : GameRepairCommand(
                        GameRepairKind.addDependency,
                        entity.nodeId!,
                        dependency,
                      ),
              ),
            );
          }
        }
        for (final field in descriptor?.fields ?? <GameFieldDescriptor>[]) {
          final error = field.validate(component.data[field.name]);
          if (error != null) {
            issues.add(
              GameAuthoringIssue(
                error,
                nodeId: entity.nodeId,
                component: component.type,
                field: field.name,
              ),
            );
          }
        }
      }
    }
    if (issues.isEmpty && expansionError != null) {
      issues.add(GameAuthoringIssue(expansionError.toString()));
    }
    return List.unmodifiable(issues);
  }
}
