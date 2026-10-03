part of '../levels.dart';

/// Navigation retains the source geometry and settings used by the shared baker.
final class GameNavigationBake {
  final String documentGeometryHash;
  final BakedNavigationMesh mesh;
  const GameNavigationBake._(this.documentGeometryHash, this.mesh);
  bool isCurrent(StudioDocument document) =>
      documentGeometryHash == GameLevelAuthoring.geometryHash(document);
  Map<String, Object?> toJson() => {
    'documentGeometryHash': documentGeometryHash,
    'settings': mesh.settings.json,
    'sources': [
      for (final g in mesh.geometry)
        {
          'id': g.sourceId,
          'revision': g.revision,
          'vertices': [for (final v in g.vertices) v.storage],
          'triangles': g.triangles,
        },
    ],
  };
  factory GameNavigationBake.fromJson(Map<String, Object?> data) {
    final s = Map<String, Object?>.from(data['settings'] as Map);
    final settings = NavigationBakeSettings(
      cellSize: (s['cellSize'] as num).toDouble(),
      radius: (s['radius'] as num).toDouble(),
      height: (s['height'] as num).toDouble(),
      maxSlope: (s['maxSlope'] as num).toDouble(),
      maxStep: (s['maxStep'] as num).toDouble(),
      maxCells: s['maxCells'] as int,
      maxTriangles: s['maxTriangles'] as int,
      maxOperations: s['maxOperations'] as int,
    );
    final sources = (data['sources'] as List).map((raw) {
      final g = raw as Map;
      return NavigationGeometry(
        sourceId: g['id'] as String,
        revision: g['revision'] as String,
        vertices: (g['vertices'] as List).map(
          (v) => Vec3(
            (v[0] as num).toDouble(),
            (v[1] as num).toDouble(),
            (v[2] as num).toDouble(),
          ),
        ),
        triangles: (g['triangles'] as List).map(
          (v) => List<int>.from(v as List),
        ),
      );
    });
    return GameNavigationBake._(
      data['documentGeometryHash'] as String,
      NavigationBaker(settings: settings).bake(sources),
    );
  }
}

final class GameLevelAuthoring {
  final GameAuthoring authoring;
  GameLevelAuthoring(this.authoring);
  Map<String, Object?> settings(StudioDocument document) {
    final values = authoring
        .editableEntities(document)
        .expand((e) => e.components)
        .where((c) => c.type == 'game.level-settings')
        .toList();
    if (values.length > 1) {
      throw StateError('A level has one settings component.');
    }
    return values.isEmpty
        ? {'profile': GameBuildProfile(id: 'native').toJson()}
        : values.single.data;
  }

  GameBuildProfile profile(StudioDocument document) =>
      GameBuildProfile.fromJson(
        Map<String, Object?>.from(settings(document)['profile'] as Map),
      );
  StudioDocument setProfile(StudioDocument document, GameBuildProfile value) =>
      _settings(document, {...settings(document), 'profile': value.toJson()});
  StudioDocument saveNavigation(
    StudioDocument document,
    GameNavigationBake value,
  ) {
    if (!value.isCurrent(document)) {
      throw StateError('Navigation geometry changed. Bake again.');
    }
    return _settings(document, {
      ...settings(document),
      'navigation': value.toJson(),
    });
  }

  GameNavigationBake? navigation(StudioDocument document) {
    final data = settings(document)['navigation'];
    return data == null
        ? null
        : GameNavigationBake.fromJson(Map<String, Object?>.from(data as Map));
  }

  StudioDocument _settings(StudioDocument document, Map<String, Object?> data) {
    final entity = authoring
        .editableEntities(document)
        .where((e) => e.components.any((c) => c.type == 'game.level-settings'))
        .firstOrNull;
    var next = document;
    if (entity == null) {
      if (document.expandedNodes.containsKey('game-settings')) {
        throw StateError('Game settings node ID is already used.');
      }
      next = document.copyWith(
        nodes: [
          ...document.nodes,
          StudioNode(
            id: 'game-settings',
            label: 'Game settings',
            kind: StudioNodeKind.group,
          ),
        ],
      );
    }
    return _upsert(
      next,
      entity?.nodeId ?? 'game-settings',
      GameComponentRecord('game.level-settings', 1, data),
    );
  }

  static List<Object?> _colliderSources(StudioExtensionRecord? record) {
    if (record == null) return [];
    final entities = record.data['entities'];
    if (entities is! List) {
      throw const FormatException('Invalid game entities.');
    }
    return [
      for (final entity in entities)
        if (entity is Map)
          for (final component in entity['components'] as List)
            if (component is Map && component['type'] == 'game.collider')
              {
                'id': entity['id'],
                'nodeId': entity['nodeId'],
                'collider': component,
              },
    ];
  }

  static String geometryHash(StudioDocument document) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'nodes': [
              for (final n in document.expandedNodes.values)
                if (n.id != 'game-settings' ||
                    n.kind != StudioNodeKind.group ||
                    n.assetId != null ||
                    document.expandedNodes.values.any(
                      (child) => child.parentId == n.id,
                    ))
                  n.toJson(),
            ],
            'assets': [for (final a in document.assets) a.toJson()],
            'colliders': _colliderSources(document.extensions['zyren.game']),
            'prefabColliders': {
              for (final p in document.prefabs)
                p.id: _colliderSources(p.extensions['zyren.game']),
            },
          }),
        ),
      )
      .toString();
  GameNavigationBake bakeNavigation(
    StudioDocument document,
    Iterable<NavigationGeometry> sources, {
    NavigationBakeSettings? settings,
    bool Function()? cancelled,
  }) => GameNavigationBake._(
    geometryHash(document),
    NavigationBaker(settings: settings).bake(sources, cancelled: cancelled),
  );
  StudioDocument bindCollider(
    StudioDocument document,
    String nodeId,
    GameColliderDefinition definition,
  ) => _upsert(
    document,
    nodeId,
    GameComponentRecord('game.collider', 1, definition.toJson()),
  );
  StudioDocument spawn(StudioDocument document, String nodeId, String group) =>
      _upsert(
        document,
        nodeId,
        GameComponentRecord('game.spawn', 1, {'group': group}),
      );
  StudioDocument checkpoint(
    StudioDocument document,
    String nodeId, {
    required String spawnEntity,
    double radius = 2,
  }) => _upsert(
    document,
    nodeId,
    GameComponentRecord('game.checkpoint', 1, {
      'spawn': spawnEntity,
      'radius': radius,
    }),
  );
  StudioDocument link(
    StudioDocument document,
    String nodeId, {
    required String targetLevel,
    required String spawnGroup,
  }) => _upsert(
    document,
    nodeId,
    GameComponentRecord('game.level-link', 1, {
      'level': targetLevel,
      'spawnGroup': spawnGroup,
    }),
  );
  StudioDocument _upsert(
    StudioDocument document,
    String nodeId,
    GameComponentRecord record,
  ) {
    if (authoring
            .entityFor(document, nodeId)
            ?.components
            .any((c) => c.type == record.type) ??
        false) {
      return authoring.setFields(
        document,
        nodeId: nodeId,
        component: record.type,
        fields: record.data,
      );
    }
    return authoring.addComponent(document, nodeId, record);
  }

  List<String> validateLinks(Iterable<StudioDocument> documents) {
    final levels = {
      for (final d in documents)
        authoring.expanded(d).levelId: authoring.expanded(d),
    };
    return [
      for (final level in levels.values)
        for (final entity in level.entities)
          for (final c in entity.components.where(
            (c) => c.type == 'game.level-link',
          ))
            if (!levels.containsKey(c.data['level']) ||
                !levels[c.data['level']]!.entities.any(
                  (e) => e.components.any(
                    (v) =>
                        v.type == 'game.spawn' &&
                        v.data['group'] == c.data['spawnGroup'],
                  ),
                ))
              '${level.levelId}/${entity.id}: target level or spawn group is missing.',
    ];
  }
}
