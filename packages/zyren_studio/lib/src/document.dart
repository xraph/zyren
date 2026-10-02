part of '../zyren_studio.dart';

enum StudioNodeKind { group, box }

/// An authored instance ID survives rebuilding; sourceId belongs to the importer.
final class StudioNode {
  final String id, label;
  final String? parentId, sourceId;
  final StudioNodeKind kind;
  final Vec3 position, scale, size;
  final Quat rotation;
  final bool visible;
  final int color;

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
  }) : rotation = rotation.normalized() {
    _text(id, 'Node ID');
    _text(label, 'Node label');
    if (parentId != null) _text(parentId!, 'Parent ID');
    if (sourceId != null) _text(sourceId!, 'Source ID');
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
  );
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

/// Version one supports groups and diffuse boxes, plus the existing review schema.
final class StudioDocument {
  static const schemaVersion = 1;
  static const maxCharacters = 4 * 1024 * 1024;
  static const maxNodes = 1000;
  static const maxDepth = 64;
  final String id, title;
  final List<StudioNode> nodes;
  final StudioCamera camera;
  final EngineeringDocument review;

  StudioDocument({
    required this.id,
    required this.title,
    required Iterable<StudioNode> nodes,
    StudioCamera? camera,
    EngineeringDocument? review,
  }) : nodes = List.unmodifiable(nodes),
       camera = camera ?? StudioCamera(),
       review = review ?? EngineeringDocument(id: id) {
    _text(id, 'Document ID');
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(id)) {
      throw ArgumentError(
        'Document ID must be a registry-compatible identifier.',
      );
    }
    _text(title, 'Title');
    if (this.nodes.length > maxNodes) throw ArgumentError('Too many nodes.');
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
  }

  String encode() {
    final result = jsonEncode({
      'schemaVersion': schemaVersion,
      'documentId': id,
      'title': title,
      'nodes': nodes.map((node) => node.toJson()).toList(),
      'camera': camera.toJson(),
      'review': jsonDecode(review.encode()),
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
      if (root['schemaVersion'] != schemaVersion) {
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
