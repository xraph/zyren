part of '../zyren_studio.dart';

enum StudioNodeKind {
  group,
  box,
  asset,
  prefab,
  sphere,
  cylinder,
  cone,
  torus,
  plane,
}

extension StudioPrimitiveKind on StudioNodeKind {
  bool get isPrimitive => const {
    StudioNodeKind.box,
    StudioNodeKind.sphere,
    StudioNodeKind.cylinder,
    StudioNodeKind.cone,
    StudioNodeKind.torus,
    StudioNodeKind.plane,
  }.contains(this);
}

/// An authored instance ID survives rebuilding; sourceId belongs to the importer.
final class StudioNode {
  final String id, label;
  final String? parentId, sourceId;
  final StudioNodeKind kind;
  final Vec3 position, scale, size;
  final Quat rotation;
  final bool visible;
  final int color;
  final StudioMaterial? material;
  final String? assetId, prefabId;
  final Map<String, StudioOverride> overrides;

  StudioNode({
    required this.id,
    required this.label,
    this.parentId,
    this.sourceId,
    this.kind = StudioNodeKind.box,
    this.position = Vec3.zero,
    this.scale = Vec3.one,
    this.size = Vec3.one,
    Quat rotation = Quat.identity,
    this.visible = true,
    this.color = 0x78dace,
    this.material,
    this.assetId,
    this.prefabId,
    Map<String, StudioOverride> overrides = const {},
  }) : rotation = rotation.normalized(),
       overrides = Map.unmodifiable(overrides) {
    _text(id, 'Node ID');
    _text(label, 'Node label');
    if (parentId != null) _text(parentId!, 'Parent ID');
    if (sourceId != null) _text(sourceId!, 'Source ID');
    if ((kind == StudioNodeKind.asset) != (assetId != null) ||
        (kind == StudioNodeKind.prefab) != (prefabId != null) ||
        overrides.isNotEmpty && kind != StudioNodeKind.prefab ||
        overrides.length > 1000) {
      throw ArgumentError('Node references must match their kind.');
    }
    if (assetId != null) _text(assetId!, 'Asset reference');
    if (prefabId != null) _text(prefabId!, 'Prefab reference');
    for (final key in overrides.keys) {
      _text(key, 'Override path');
    }
    if (!position.isFinite ||
        !scale.isFinite ||
        !size.isFinite ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0 ||
        size.x <= 0 ||
        size.y <= 0 ||
        size.z <= 0 ||
        color < 0 ||
        color > 0xffffff) {
      throw ArgumentError('Invalid node dimensions, transform or color.');
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'parentId': parentId,
    'sourceId': sourceId,
    'kind': kind.name,
    'position': position.storage,
    'scale': scale.storage,
    'rotation': [rotation.x, rotation.y, rotation.z, rotation.w],
    'size': size.storage,
    'visible': visible,
    'color': color,
    if (material != null) 'material': material!.toJson(),
    if (assetId != null) 'assetId': assetId,
    if (prefabId != null) 'prefabId': prefabId,
    if (overrides.isNotEmpty)
      'overrides': overrides.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory StudioNode.fromJson(Map<String, dynamic> value) => StudioNode(
    id: value['id'] as String,
    label: value['label'] as String,
    parentId: value['parentId'] as String?,
    sourceId: value['sourceId'] as String?,
    kind: StudioNodeKind.values.byName(value['kind'] as String),
    position: _vector(value['position']),
    scale: _vector(value['scale']),
    size: _vector(value['size']),
    rotation: _rotation(value['rotation']),
    visible: value['visible'] as bool,
    color: value['color'] as int,
    material: value['material'] == null
        ? null
        : StudioMaterial.fromJson(value['material'] as Map<String, dynamic>),
    assetId: value['assetId'] as String?,
    prefabId: value['prefabId'] as String?,
    overrides: (value['overrides'] as Map<String, dynamic>? ?? {}).map(
      (key, v) =>
          MapEntry(key, StudioOverride.fromJson(v as Map<String, dynamic>)),
    ),
  );

  StudioNode copyWith({
    String? id,
    String? label,
    String? parentId,
    bool clearParent = false,
    String? sourceId,
    bool clearSource = false,
    StudioNodeKind? kind,
    Vec3? position,
    Vec3? scale,
    Vec3? size,
    Quat? rotation,
    bool? visible,
    int? color,
    StudioMaterial? material,
    bool clearMaterial = false,
    String? assetId,
    String? prefabId,
    Map<String, StudioOverride>? overrides,
  }) {
    final nextKind = kind ?? this.kind;
    return StudioNode(
      id: id ?? this.id,
      label: label ?? this.label,
      parentId: clearParent ? null : parentId ?? this.parentId,
      sourceId: clearSource ? null : sourceId ?? this.sourceId,
      kind: nextKind,
      position: position ?? this.position,
      scale: scale ?? this.scale,
      size: size ?? this.size,
      rotation: rotation ?? this.rotation,
      visible: visible ?? this.visible,
      color: color ?? this.color,
      material: clearMaterial ? null : material ?? this.material,
      assetId: nextKind == StudioNodeKind.asset
          ? assetId ?? this.assetId
          : null,
      prefabId: nextKind == StudioNodeKind.prefab
          ? prefabId ?? this.prefabId
          : null,
      overrides: nextKind == StudioNodeKind.prefab
          ? overrides ?? this.overrides
          : const {},
    );
  }
}

/// Immutable perspective view settings, independent of an attached renderer.
final class StudioCamera {
  final Vec3 position, target, up;
  final double fieldOfView, near, far, zoom;
  StudioCamera({
    this.position = const Vec3(5, 3, 7),
    this.target = Vec3.zero,
    this.up = const Vec3(0, 1, 0),
    this.fieldOfView = .8726646259971648,
    this.near = .1,
    this.far = 1000,
    this.zoom = 1,
  }) {
    createCamera();
  }

  factory StudioCamera.capture(PerspectiveCamera camera) => StudioCamera(
    position: camera.position,
    target: camera.target,
    up: camera.up,
    fieldOfView: camera.fieldOfView,
    near: camera.near,
    far: camera.far,
    zoom: camera.zoom,
  );

  PerspectiveCamera createCamera() => PerspectiveCamera(
    position: position,
    target: target,
    up: up,
    fieldOfView: fieldOfView,
    near: near,
    far: far,
    zoom: zoom,
  );

  Map<String, Object?> toJson() => {
    'position': position.storage,
    'target': target.storage,
    'up': up.storage,
    'fieldOfView': fieldOfView,
    'near': near,
    'far': far,
    'zoom': zoom,
  };

  factory StudioCamera.fromJson(Map<String, dynamic> value) => StudioCamera(
    position: _vector(value['position']),
    target: _vector(value['target']),
    up: _vector(value['up']),
    fieldOfView: (value['fieldOfView'] as num).toDouble(),
    near: (value['near'] as num).toDouble(),
    far: (value['far'] as num).toDouble(),
    zoom: (value['zoom'] as num).toDouble(),
  );
}

/// Saved authoring data. Version-one documents migrate when read and next saved.
final class StudioDocument {
  static const schemaVersion = 3;
  static const maxCharacters = 4 * 1024 * 1024;
  static const maxNodes = 1000;
  static const maxDepth = 64;
  final String id, title;
  final List<StudioNode> nodes;
  final StudioCamera camera;
  final EngineeringDocument review;
  final List<StudioAsset> assets;
  final List<StudioPrefab> prefabs;
  final List<StudioClip> clips;
  late final Map<String, StudioNode> expandedNodes;
  late final Map<String, String> prefabOwners;

  StudioDocument({
    required this.id,
    required this.title,
    required Iterable<StudioNode> nodes,
    StudioCamera? camera,
    EngineeringDocument? review,
    Iterable<StudioAsset> assets = const [],
    Iterable<StudioPrefab> prefabs = const [],
    Iterable<StudioClip> clips = const [],
  }) : nodes = List.unmodifiable(nodes),
       camera = camera ?? StudioCamera(),
       review = review ?? EngineeringDocument(id: id),
       assets = List.unmodifiable(assets),
       prefabs = List.unmodifiable(prefabs),
       clips = List.unmodifiable(clips) {
    _text(id, 'Document ID');
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(id)) {
      throw ArgumentError(
        'Document ID must be a registry-compatible identifier.',
      );
    }
    _text(title, 'Title');
    if (this.nodes.length > maxNodes) throw ArgumentError('Too many nodes.');
    if (this.assets.length > 32 ||
        this.prefabs.length > 64 ||
        this.clips.length > 64 ||
        this.assets.map((a) => a.id).toSet().length != this.assets.length ||
        this.prefabs.map((p) => p.id).toSet().length != this.prefabs.length ||
        this.clips.map((c) => c.id).toSet().length != this.clips.length) {
      throw ArgumentError(
        'Authoring definitions exceed limits or contain duplicate IDs.',
      );
    }
    if (this.review.id != id) {
      throw ArgumentError('Review document ID differs.');
    }
    final byId = <String, StudioNode>{};
    final sources = <String>{};
    for (final node in this.nodes) {
      if (byId.containsKey(node.id)) throw ArgumentError('Duplicate node ID.');
      byId[node.id] = node;
      if (node.sourceId != null &&
          (!this.review.objects.containsKey(node.sourceId) ||
              !sources.add(node.sourceId!))) {
        throw ArgumentError(
          'Source IDs must be unique existing review records.',
        );
      }
    }
    for (final node in this.nodes) {
      final visited = <String>{};
      for (StudioNode? current = node; current != null;) {
        if (!visited.add(current.id) || visited.length > maxDepth) {
          throw ArgumentError(
            'Hierarchy contains a cycle or exceeds $maxDepth levels.',
          );
        }
        final parent = current.parentId;
        if (parent != null && !byId.containsKey(parent)) {
          throw ArgumentError('Unknown parent $parent.');
        }
        current = byId[parent];
      }
    }
    final assetIds = this.assets.map((a) => a.id).toSet();
    final definitions = {for (final p in this.prefabs) p.id: p};
    for (final node in [
      ...this.nodes,
      ...this.prefabs.expand((p) => p.nodes),
    ]) {
      if (node.assetId != null && !assetIds.contains(node.assetId) ||
          node.prefabId != null && !definitions.containsKey(node.prefabId)) {
        throw ArgumentError('Node references an unknown asset or prefab.');
      }
    }
    final prefabDepths = <String, int>{};
    int checkPrefab(String id, Set<String> path) {
      if (path.length >= maxDepth || path.contains(id)) {
        throw ArgumentError('Cyclic or excessively nested prefab definitions.');
      }
      if (prefabDepths[id] case final known?) return known;
      var depth = 1;
      for (final node in definitions[id]!.nodes) {
        if (node.prefabId != null) {
          final childDepth = 1 + checkPrefab(node.prefabId!, {...path, id});
          if (childDepth > depth) depth = childDepth;
        }
      }
      if (depth > maxDepth) throw ArgumentError('Prefab depth exceeds limits.');
      return prefabDepths[id] = depth;
    }

    for (final id in definitions.keys) {
      checkPrefab(id, {});
    }
    final expanded = <String, StudioNode>{};
    final owners = <String, String>{};
    void expand(
      StudioNode node,
      String? owner,
      String path,
      Map<String, StudioOverride> inherited,
      int depth,
    ) {
      if (depth > maxDepth ||
          expanded.length >= 10000 ||
          expanded.containsKey(node.id)) {
        throw ArgumentError('Expanded prefab identities or size are invalid.');
      }
      final effective = inherited[path]?.apply(node) ?? node;
      expanded[node.id] = effective;
      if (owner != null) owners[node.id] = owner;
      if (node.prefabId == null) return;
      final nextOwner = owner ?? node.id;
      final localOverrides = <String, StudioOverride>{
        for (final e in node.overrides.entries)
          (path.isEmpty ? e.key : '$path/${e.key}'): e.value,
        ...inherited,
      };
      for (final child in definitions[node.prefabId]!.nodes) {
        final childPath = path.isEmpty ? child.id : '$path/${child.id}';
        final childId = '$nextOwner/$childPath';
        final parentId = child.parentId == null
            ? node.id
            : '$nextOwner/${path.isEmpty ? child.parentId : '$path/${child.parentId}'}';
        expand(
          child.copyWith(id: childId, parentId: parentId),
          nextOwner,
          childPath,
          localOverrides,
          depth + 1,
        );
      }
      for (final key in node.overrides.keys) {
        final fullPath = path.isEmpty ? key : '$path/$key';
        if (!expanded.containsKey('$nextOwner/$fullPath')) {
          throw ArgumentError('Override target is missing.');
        }
      }
    }

    for (final node in this.nodes) {
      expand(node, null, '', const {}, 0);
    }
    _validateHierarchy(expanded.values.toList());
    expandedNodes = Map.unmodifiable(expanded);
    prefabOwners = Map.unmodifiable(owners);
    for (final clip in this.clips) {
      if (clip.tracks.keys.any((id) => !expanded.containsKey(id))) {
        throw ArgumentError('Clip target is missing.');
      }
    }
  }

  StudioDocument copyWith({
    Iterable<StudioNode>? nodes,
    StudioCamera? camera,
    EngineeringDocument? review,
    Iterable<StudioAsset>? assets,
    Iterable<StudioPrefab>? prefabs,
    Iterable<StudioClip>? clips,
    String? title,
  }) => StudioDocument(
    id: id,
    title: title ?? this.title,
    nodes: nodes ?? this.nodes,
    camera: camera ?? this.camera,
    review: review ?? this.review,
    assets: assets ?? this.assets,
    prefabs: prefabs ?? this.prefabs,
    clips: clips ?? this.clips,
  );

  String encode() {
    final result = jsonEncode({
      'schemaVersion': schemaVersion,
      'documentId': id,
      'title': title,
      'nodes': nodes.map((node) => node.toJson()).toList(),
      'camera': camera.toJson(),
      'review': jsonDecode(review.encode()),
      'assets': assets.map((a) => a.toJson()).toList(),
      'prefabs': prefabs.map((p) => p.toJson()).toList(),
      'clips': clips.map((c) => c.toJson()).toList(),
    });
    if (result.length > maxCharacters) {
      throw StateError('Scene exceeds size limit.');
    }
    return result;
  }

  factory StudioDocument.decode(String source) {
    if (source.length > maxCharacters) {
      throw const FormatException('Scene exceeds size limit.');
    }
    try {
      final root = jsonDecode(source) as Map<String, dynamic>;
      if (root['schemaVersion'] != schemaVersion &&
          root['schemaVersion'] != 1 &&
          root['schemaVersion'] != 2) {
        throw const FormatException('Unsupported Studio schema version.');
      }
      final nodes = root['nodes'] as List;
      if (nodes.length > maxNodes) {
        throw const FormatException('Too many nodes.');
      }
      return StudioDocument(
        id: root['documentId'] as String,
        title: root['title'] as String,
        nodes: nodes.map(
          (node) => StudioNode.fromJson(node as Map<String, dynamic>),
        ),
        camera: StudioCamera.fromJson(root['camera'] as Map<String, dynamic>),
        review: EngineeringDocument.decode(jsonEncode(root['review'])),
        assets: (root['assets'] as List? ?? []).map(
          (a) => StudioAsset.fromJson(a as Map<String, dynamic>),
        ),
        prefabs: (root['prefabs'] as List? ?? []).map(
          (p) => StudioPrefab.fromJson(p as Map<String, dynamic>),
        ),
        clips: (root['clips'] as List? ?? []).map(
          (c) => StudioClip.fromJson(c as Map<String, dynamic>),
        ),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Studio document: ${error.message}');
    } on TypeError {
      throw const FormatException('Invalid Studio document fields.');
    }
  }
}

void _text(String value, String label) {
  if (value.trim().isEmpty || value.length > 256) {
    throw ArgumentError('$label must contain 1 to 256 characters.');
  }
}

List<double> _numbers(dynamic value, int length) {
  if (value is! List ||
      value.length != length ||
      value.any((element) => element is! num || !element.isFinite)) {
    throw const FormatException('Invalid numeric vector.');
  }
  return value.map((element) => (element as num).toDouble()).toList();
}

Vec3 _vector(dynamic value) => Vec3.array(_numbers(value, 3));
Quat _rotation(dynamic value) {
  final values = _numbers(value, 4);
  return Quat(values[0], values[1], values[2], values[3]);
}
