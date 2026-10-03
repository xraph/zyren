part of '../zyren_studio.dart';

enum StudioMaterialKind { diffuse, unlit, standard }

/// Supported authoring values. Imported texture maps stay with the source asset.
final class StudioMaterial {
  final StudioMaterialKind kind;
  final int color, emissive;
  final double opacity, metallic, roughness, emissiveIntensity;
  final bool doubleSided;
  StudioMaterial({
    this.kind = StudioMaterialKind.diffuse,
    this.color = 0x78dace,
    this.opacity = 1,
    this.metallic = 0,
    this.roughness = .7,
    this.emissive = 0,
    this.emissiveIntensity = 1,
    this.doubleSided = false,
  }) {
    if ([color, emissive].any((v) => v < 0 || v > 0xffffff) ||
        [
          opacity,
          metallic,
          roughness,
        ].any((v) => !v.isFinite || v < 0 || v > 1) ||
        !emissiveIntensity.isFinite ||
        emissiveIntensity < 0 ||
        emissiveIntensity > 1000) {
      throw ArgumentError('Invalid material values.');
    }
  }
  MeshMaterial create({MeshMaterial? imported}) {
    final side = doubleSided ? MaterialSide.doubleSided : MaterialSide.front;
    final alpha = opacity < 1
        ? MaterialAlphaMode.blend
        : MaterialAlphaMode.opaque;
    return switch (kind) {
      StudioMaterialKind.diffuse => DiffuseMaterial(
        color: Color3.hex(color),
        colorMap: imported?.colorMap,
        opacity: opacity,
        alphaMode: alpha,
        side: side,
      ),
      StudioMaterialKind.unlit => UnlitMaterial(
        color: Color3.hex(color),
        colorMap: imported?.colorMap,
        opacity: opacity,
        alphaMode: alpha,
        side: side,
      ),
      StudioMaterialKind.standard =>
        (imported is StandardMaterial
                ? imported
                : StandardMaterial(colorMap: imported?.colorMap))
            .copyWith(
              color: Color3.hex(color),
              metallic: metallic,
              roughness: roughness,
              emissive: Color3.hex(emissive),
              emissiveIntensity: emissiveIntensity,
              opacity: opacity,
              alphaMode: alpha,
              side: side,
            ),
    };
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'color': color,
    'opacity': opacity,
    'metallic': metallic,
    'roughness': roughness,
    'emissive': emissive,
    'emissiveIntensity': emissiveIntensity,
    'doubleSided': doubleSided,
  };
  factory StudioMaterial.fromJson(Map<String, dynamic> value) => StudioMaterial(
    kind: StudioMaterialKind.values.byName(value['kind'] as String),
    color: value['color'] as int,
    opacity: (value['opacity'] as num).toDouble(),
    metallic: (value['metallic'] as num).toDouble(),
    roughness: (value['roughness'] as num).toDouble(),
    emissive: value['emissive'] as int,
    emissiveIntensity: (value['emissiveIntensity'] as num).toDouble(),
    doubleSided: value['doubleSided'] as bool,
  );
}

/// Stores an adapter's versioned descriptor verbatim, without importing that adapter.
final class StudioAsset {
  final String id, label, provider;
  final Map<String, Object?> reference;
  final Map<String, int> sourceNodes;
  StudioAsset({
    required this.id,
    required this.label,
    required this.provider,
    required Map<String, Object?> reference,
    Map<String, int> sourceNodes = const {},
  }) : reference = _freezeJson(reference) as Map<String, Object?>,
       sourceNodes = Map.unmodifiable(sourceNodes) {
    _text(id, 'Asset ID');
    _text(label, 'Asset label');
    _text(provider, 'Provider');
    if (jsonEncode(reference).length > 16384 ||
        reference.isEmpty ||
        sourceNodes.length > 4096 ||
        sourceNodes.values.any((i) => i < 0) ||
        sourceNodes.values.toSet().length != sourceNodes.length) {
      throw ArgumentError('Invalid asset descriptor or source bindings.');
    }
    for (final source in sourceNodes.keys) {
      _text(source, 'Source identity');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'provider': provider,
    'reference': reference,
    'sourceNodes': sourceNodes,
  };
  factory StudioAsset.fromJson(Map<String, dynamic> value) => StudioAsset(
    id: value['id'] as String,
    label: value['label'] as String,
    provider: value['provider'] as String,
    reference: value['reference'] as Map<String, dynamic>,
    sourceNodes: (value['sourceNodes'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, value as int),
    ),
  );
}

/// Overrides belong to an instance and retain their relative prefab node keys.
final class StudioOverride {
  final Vec3? position, scale;
  final Quat? rotation;
  final bool? visible;
  final StudioMaterial? material;
  StudioOverride({
    this.position,
    this.scale,
    Quat? rotation,
    this.visible,
    this.material,
  }) : rotation = rotation?.normalized() {
    if (position != null && !position!.isFinite ||
        scale != null &&
            (!scale!.isFinite ||
                scale!.x == 0 ||
                scale!.y == 0 ||
                scale!.z == 0)) {
      throw ArgumentError('Invalid instance override.');
    }
  }
  StudioNode apply(StudioNode node) => node.copyWith(
    position: position,
    scale: scale,
    rotation: rotation,
    visible: visible,
    material: material,
  );
  Map<String, Object?> toJson() => {
    if (position != null) 'position': position!.storage,
    if (scale != null) 'scale': scale!.storage,
    if (rotation != null)
      'rotation': [rotation!.x, rotation!.y, rotation!.z, rotation!.w],
    if (visible != null) 'visible': visible,
    if (material != null) 'material': material!.toJson(),
  };
  factory StudioOverride.fromJson(Map<String, dynamic> value) => StudioOverride(
    position: value['position'] == null ? null : _vector(value['position']),
    scale: value['scale'] == null ? null : _vector(value['scale']),
    rotation: value['rotation'] == null ? null : _rotation(value['rotation']),
    visible: value['visible'] as bool?,
    material: value['material'] == null
        ? null
        : StudioMaterial.fromJson(value['material'] as Map<String, dynamic>),
  );
}

final class StudioPrefab {
  final String id, label, version;
  final List<StudioNode> nodes;
  StudioPrefab({
    required this.id,
    required this.label,
    required this.version,
    required Iterable<StudioNode> nodes,
  }) : nodes = List.unmodifiable(nodes) {
    _text(id, 'Prefab ID');
    _text(label, 'Prefab label');
    _text(version, 'Prefab version');
    if (this.nodes.isEmpty || this.nodes.length > StudioDocument.maxNodes) {
      throw ArgumentError('Prefab nodes exceed limits.');
    }
    _validateHierarchy(this.nodes);
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'version': version,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };
  factory StudioPrefab.fromJson(Map<String, dynamic> value) => StudioPrefab(
    id: value['id'] as String,
    label: value['label'] as String,
    version: value['version'] as String,
    nodes: (value['nodes'] as List).map(
      (n) => StudioNode.fromJson(n as Map<String, dynamic>),
    ),
  );
}

final class StudioKeyframe {
  final int microseconds;
  final Vec3 position, scale;
  final Quat rotation;
  final bool visible;
  StudioKeyframe({
    required this.microseconds,
    required this.position,
    this.scale = Vec3.one,
    Quat rotation = Quat.identity,
    this.visible = true,
  }) : rotation = rotation.normalized() {
    if (microseconds < 0 ||
        microseconds > 86400000000 ||
        !position.isFinite ||
        !scale.isFinite ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0) {
      throw ArgumentError('Invalid authored keyframe.');
    }
  }
  Map<String, Object?> toJson() => {
    'microseconds': microseconds,
    'position': position.storage,
    'scale': scale.storage,
    'rotation': [rotation.x, rotation.y, rotation.z, rotation.w],
    'visible': visible,
  };
  factory StudioKeyframe.fromJson(Map<String, dynamic> value) => StudioKeyframe(
    microseconds: value['microseconds'] as int,
    position: _vector(value['position']),
    scale: _vector(value['scale']),
    rotation: _rotation(value['rotation']),
    visible: value['visible'] as bool,
  );
}

final class StudioClip {
  final String id, label;
  final int durationMicroseconds;
  final Map<String, List<StudioKeyframe>> tracks;
  StudioClip({
    required this.id,
    required this.label,
    required this.durationMicroseconds,
    required Map<String, List<StudioKeyframe>> tracks,
  }) : tracks = Map.unmodifiable(
         tracks.map(
           (key, value) =>
               MapEntry(key, List<StudioKeyframe>.unmodifiable(value)),
         ),
       ) {
    _text(id, 'Clip ID');
    _text(label, 'Clip label');
    if (durationMicroseconds <= 0 ||
        durationMicroseconds > 86400000000 ||
        tracks.isEmpty ||
        tracks.length > 128 ||
        tracks.values.fold(0, (int sum, frames) => sum + frames.length) >
            4096) {
      throw ArgumentError('Invalid clip duration or track budget.');
    }
    for (final entry in this.tracks.entries) {
      _text(entry.key, 'Track target');
      if (entry.value.isEmpty) throw ArgumentError('A track needs keyframes.');
      StudioKeyframe? prior;
      for (final frame in entry.value) {
        if (frame.microseconds > durationMicroseconds ||
            prior != null &&
                (prior.microseconds >= frame.microseconds ||
                    prior.scale.x.sign != frame.scale.x.sign ||
                    prior.scale.y.sign != frame.scale.y.sign ||
                    prior.scale.z.sign != frame.scale.z.sign)) {
          throw ArgumentError(
            'Keyframe times must increase and scales cannot cross zero.',
          );
        }
        prior = frame;
      }
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'durationMicroseconds': durationMicroseconds,
    'tracks': tracks.map(
      (key, frames) => MapEntry(key, frames.map((f) => f.toJson()).toList()),
    ),
  };
  factory StudioClip.fromJson(Map<String, dynamic> value) => StudioClip(
    id: value['id'] as String,
    label: value['label'] as String,
    durationMicroseconds: value['durationMicroseconds'] as int,
    tracks: (value['tracks'] as Map<String, dynamic>).map(
      (key, frames) => MapEntry(
        key,
        (frames as List)
            .map((f) => StudioKeyframe.fromJson(f as Map<String, dynamic>))
            .toList(),
      ),
    ),
  );
}

Object? _freezeJson(Object? value, [int depth = 0]) {
  if (depth > 16) throw ArgumentError('Descriptor nesting exceeds limits.');
  if (value == null ||
      value is String ||
      value is bool ||
      value is num && value.isFinite) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((v) => _freezeJson(v, depth + 1)),
    );
  }
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, v) => MapEntry(key, _freezeJson(v, depth + 1))),
    );
  }
  throw ArgumentError('Descriptors must contain finite JSON values.');
}

void _validateHierarchy(List<StudioNode> nodes) {
  final byId = {for (final node in nodes) node.id: node};
  if (byId.length != nodes.length) throw ArgumentError('Duplicate node ID.');
  for (final node in nodes) {
    final visited = <String>{};
    for (StudioNode? current = node; current != null;) {
      if (!visited.add(current.id) ||
          visited.length > StudioDocument.maxDepth) {
        throw ArgumentError(
          'Hierarchy contains a cycle or exceeds depth limits.',
        );
      }
      final parent = current.parentId;
      if (parent != null && !byId.containsKey(parent)) {
        throw ArgumentError('Unknown parent $parent.');
      }
      current = byId[parent];
    }
  }
}
