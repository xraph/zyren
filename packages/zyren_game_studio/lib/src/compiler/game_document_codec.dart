part of '../../compiler.dart';

final class GameDocumentData {
  final String projectId, levelId;
  final List<GameEntityRecord> entities;
  GameDocumentData({
    required this.projectId,
    required this.levelId,
    required List<GameEntityRecord> entities,
  }) : entities = List.unmodifiable(entities);
}

/// Entity references belong to component codecs; node references belong to Studio.
final class GameDocumentCodec implements StudioExtensionCodec {
  final GameRegistry registry;
  GameDocumentCodec(this.registry);
  @override
  String get namespace => 'zyren.game';
  @override
  int get schemaVersion => 1;
  GameDocumentData read(StudioExtensionRecord record) {
    if (record.namespace != namespace || record.schemaVersion != schemaVersion) {
      throw FormatException('Unsupported game document extension.');
    }
    final data = record.data;
    final entities = (data['entities'] as List)
        .map(
          (e) => GameEntityRecord.fromJson(Map<String, Object?>.from(e as Map)),
        )
        .toList();
    final result = GameDocumentData(
      projectId: data['projectId'] as String,
      levelId: data['levelId'] as String,
      entities: entities,
    );
    // References may target inherited entities. Validate the complete set after expansion.
    GameSceneIdentity(result.projectId, result.levelId);
    if (entities.length > registry.limits.maxEntities ||
        entities.map((e) => e.id).toSet().length != entities.length) {
      throw FormatException('Invalid authored game entities.');
    }
    for (final entity in entities) {
      if (entity.components.length > registry.limits.maxComponentsPerEntity) {
        throw FormatException('Component limit exceeded.');
      }
      for (final component in entity.components) {
        registry.normalize(component);
        registry.references(component);
      }
    }
    return result;
  }

  StudioExtensionRecord write(GameDocumentData data, {bool required = true}) =>
      StudioExtensionRecord(
        namespace: namespace,
        schemaVersion: schemaVersion,
        required: required,
        data: {
          'projectId': data.projectId,
          'levelId': data.levelId,
          'entities': data.entities.map((e) => e.toJson()).toList(),
        },
      );
  @override
  void validate(StudioExtensionRecord record, StudioDocument document) {
    final data = read(record);
    if (data.entities.any(
      (e) => e.nodeId != null && !document.expandedNodes.containsKey(e.nodeId),
    )) {
      throw FormatException('Game entity references a missing expanded node.');
    }
    expand(document);
  }

  /// Resolve Studio's prefab tree, applying relative overrides before prefixing.
  GameDocumentData expand(StudioDocument document) {
    final record = document.extensions[namespace];
    if (record == null) throw FormatException('Game extension is missing.');
    final base = read(record);
    final prefabs = {for (final prefab in document.prefabs) prefab.id: prefab};
    List<GameEntityRecord> prefix(
      List<GameEntityRecord> entities,
      StudioNode instance,
    ) {
      var data = GameDocumentData(
        projectId: base.projectId,
        levelId: base.levelId,
        entities: entities,
      );
      final overrides = instance.extensionOverrides[namespace];
      if (overrides != null) {
        data = read(applyOverrides(write(data), overrides));
      }
      final template = GameSpawnTemplate(
        id: instance.prefabId!,
        entities: data.entities
            .map(
              (e) => GameEntityRecord(
                id: e.id,
                nodeId: e.nodeId,
                components: e.components
                    .map(
                      (c) => !registry.supports(c) && c.required
                          ? GameComponentRecord(
                              c.type,
                              c.version,
                              c.data,
                              required: false,
                            )
                          : c,
                    )
                    .toList(),
              ),
            )
            .toList(),
        registry: registry,
      );
      return template.instantiate(instance.id).indexed.map((entry) {
        final (index, e) = entry;
        return GameEntityRecord(
          id: e.id,
          nodeId: e.nodeId == null ? null : '${instance.id}/${e.nodeId}',
          components: e.components.indexed
              .map(
                (c) => GameComponentRecord(
                  c.$2.type,
                  c.$2.version,
                  c.$2.data,
                  required: data.entities[index].components[c.$1].required,
                ),
              )
              .toList(),
        );
      }).toList();
    }

    List<GameEntityRecord> local(String id, Set<String> active) {
      if (!active.add(id) || active.length > StudioDocument.maxDepth) {
        throw FormatException('Cyclic game prefab expansion.');
      }
      final prefab = prefabs[id];
      if (prefab == null) throw FormatException('Game prefab is missing.');
      final own = prefab.extensions[namespace];
      final entities = <GameEntityRecord>[
        if (own != null) ...read(own).entities,
      ];
      for (final node in prefab.nodes) {
        if (node.prefabId != null) {
          entities.addAll(prefix(local(node.prefabId!, {...active}), node));
        }
      }
      return entities;
    }

    final entities = <GameEntityRecord>[...base.entities];
    for (final instance in document.nodes) {
      if (instance.prefabId != null) {
        entities.addAll(prefix(local(instance.prefabId!, {}), instance));
      }
    }
    final checked = GameProject(
      id: base.projectId,
      startupLevel: base.levelId,
      registry: registry,
      levels: [
        GameLevel(
          id: base.levelId,
          scene: GameSceneIdentity(document.id, 'expanded'),
          entities: entities,
        ),
      ],
    ).levels.single.entities;
    if (checked.any(
      (e) => e.nodeId != null && !document.expandedNodes.containsKey(e.nodeId),
    )) {
      throw FormatException('Expanded game node is missing.');
    }
    return GameDocumentData(
      projectId: base.projectId,
      levelId: base.levelId,
      entities: checked,
    );
  }

  @override
  StudioExtensionRecord migrate(StudioExtensionRecord record) =>
      throw FormatException('Unsupported game document migration.');
  @override
  Iterable<String> referencedNodeIds(StudioExtensionRecord record) =>
      read(record).entities.map((e) => e.nodeId).whereType<String>();
  @override
  StudioExtensionRecord remapNodeIds(
    StudioExtensionRecord record,
    Map<String, String> ids,
  ) {
    final data = read(record);
    String mappedId(GameEntityRecord entity) {
      final node = ids[entity.nodeId];
      if (node == null) return entity.id;
      return entity.id == entity.nodeId
          ? node
          : '${Uri.encodeComponent(node)}/${Uri.encodeComponent(entity.id)}';
    }

    final entityIds = {
      for (final entity in data.entities) entity.id: mappedId(entity),
    };
    final mapped = data.entities
        .map(
          (entity) => GameEntityRecord(
            id: entityIds[entity.id]!,
            nodeId: ids[entity.nodeId] ?? entity.nodeId,
            components: entity.components.map((component) {
              if (!registry.supports(component)) {
                if (entityIds.entries.any((e) => e.key != e.value)) {
                  throw StateError(
                    'Load component codec before remapping entities.',
                  );
                }
                return component;
              }
              final json =
                  jsonDecode(jsonEncode(component.data))
                      as Map<String, dynamic>;
              for (final reference in registry.references(component)) {
                dynamic current = json;
                for (final segment in reference.path.take(
                  reference.path.length - 1,
                )) {
                  current = current[segment];
                }
                current[reference.path.last] =
                    entityIds[reference.targetId] ?? reference.targetId;
              }
              return GameComponentRecord(
                component.type,
                component.version,
                json,
                required: component.required,
              );
            }).toList(),
          ),
        )
        .toList();
    final next = write(
      GameDocumentData(
        projectId: data.projectId,
        levelId: data.levelId,
        entities: mapped,
      ),
      required: record.required,
    );
    read(next);
    return next;
  }

  @override
  StudioExtensionRecord applyOverrides(
    StudioExtensionRecord record,
    Map<String, Object?> overrides,
  ) {
    if (overrides.keys.any((k) => k != 'entities') ||
        overrides['entities'] is! Map) {
      throw ArgumentError('Expected entity component overrides.');
    }
    final data = read(record), edits = overrides['entities'] as Map;
    if (edits.keys.any((k) => !data.entities.any((e) => e.id == k))) {
      throw ArgumentError('Unknown entity override.');
    }
    final entities = data.entities.map((entity) {
      final edit = edits[entity.id];
      if (edit == null) return entity;
      if (edit is! Map || edit.length != 1 || edit['components'] is! Map) {
        throw ArgumentError('Expected component field overrides.');
      }
      final components = edit['components'] as Map;
      if (components.keys.any(
        (k) => !entity.components.any((c) => c.type == k),
      )) {
        throw ArgumentError('Unknown component override.');
      }
      return GameEntityRecord(
        id: entity.id,
        nodeId: entity.nodeId,
        components: entity.components.map((component) {
          final fields = components[component.type];
          if (fields == null) return component;
          if (!registry.supports(component) || fields is! Map<String, Object?>) {
            throw StateError('Component override codec is unavailable.');
          }
          return registry.normalize(
            GameComponentRecord(component.type, component.version, {
              ...component.data,
              ...fields,
            }, required: component.required),
          );
        }).toList(),
      );
    }).toList();
    final next = write(
      GameDocumentData(
        projectId: data.projectId,
        levelId: data.levelId,
        entities: entities,
      ),
      required: record.required,
    );
    read(next);
    return next;
  }
}
