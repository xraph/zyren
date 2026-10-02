part of '../zyren_studio.dart';

/// Reconstructs owned content without serializing renderer helpers or runtime IDs.
final class StudioScene {
  final StudioDocument document;
  final Scene scene = Scene();
  final Group content = Group(name: 'Authored scene');
  late final PerspectiveCamera camera = document.camera.createCamera();
  final SceneToolsPlugin tools = SceneToolsPlugin(highlightSelection: false);
  late final SceneEngineeringPlugin engineering = SceneEngineeringPlugin(
    document: document.review,
  );
  final Map<String, Object3D> _objects = {};
  final Map<String, BufferGeometry> _geometries = {};
  final Map<String, MeshMaterial> _materials = {};
  final Map<String, int> _geometryRevisions = {};

  final _helpers = <bool Function(Object3D)>{};
  String? _fingerprint;
  int _revision = 0;

  /// Helper ownership is explicit because gizmos can attach inside authored groups.
  Registration registerHelper(bool Function(Object3D) owns) {
    _helpers.add(owns);
    return Registration(() => _helpers.remove(owns));
  }

  /// Revision of authored state. Helper updates do not invalidate edit commands.
  int get revision {
    final fingerprint = jsonEncode({
      'contentParent': content.parent?.id,
      'contentPose': content.localMatrix.storage,
      'contentVisible': content.visible,
      'nodes': [
        for (final object in _objects.values)
          {
            'id': object.id,
            'parent': object.parent?.id,
            'pose': object.localMatrix.storage,
            'visible': object.visible,
            if (object is Mesh)
              'geometryRevision': object.geometry.capture().revision,
            if (object is Mesh)
              'materialIdentity': identityHashCode(object.material),
          },
      ],
      'review': engineering.document.encode(),
      'camera': StudioCamera.capture(camera).toJson(),
    });
    if (_fingerprint != fingerprint) {
      _fingerprint = fingerprint;
      _revision++;
    }
    return _revision;
  }

  StudioScene(this.document) {
    scene.background = Color3.hex(0x14242b);
    scene.add(content);
    for (final node in document.nodes) {
      final Object3D object;
      if (node.kind == StudioNodeKind.box) {
        final geometry = BoxGeometry(
          width: node.size.x,
          height: node.size.y,
          depth: node.size.z,
        );
        _geometries[node.id] = geometry;
        final material = DiffuseMaterial(color: Color3.hex(node.color));
        _materials[node.id] = material;
        _geometryRevisions[node.id] = geometry.capture().revision;
        object = Mesh(geometry, material, name: node.label);
      } else {
        object = Group(name: node.label);
      }
      object.position = node.position;
      object.scale = node.scale;
      object.quaternion = node.rotation;
      object.visible = node.visible;
      _objects[node.id] = object;
    }
    for (final node in document.nodes) {
      (_objects[node.parentId] ?? content).add(_objects[node.id]!);
    }
  }

  Map<String, Object3D> get objects => Map.unmodifiable(_objects);
  String? idFor(Object3D? object) {
    for (final entry in _objects.entries) {
      if (identical(entry.value, object)) return entry.key;
    }
    return null;
  }

  /// Call after every engine attachment, including native renderer recovery.
  void bindReview() {
    for (final node in document.nodes) {
      if (node.sourceId != null) {
        engineering.bind(node.sourceId!, _objects[node.id]!);
      }
    }
  }

  /// Captures supported edits. Rejects structural changes the schema cannot save.
  StudioDocument capture() {
    if (content.parent != scene ||
        content.position != Vec3.zero ||
        content.scale != Vec3.one ||
        content.quaternion != Quat.identity ||
        !content.visible ||
        engineering.isolatedIds.isNotEmpty) {
      throw StateError(
        'Restore the authored root and review visibility before saving.',
      );
    }
    final members = <Object3D>{};
    final pending = [...content.children];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (_helpers.any((owns) => owns(node))) continue;
      members.add(node);
      pending.addAll(node.children);
    }
    if (members.length != _objects.length ||
        !members.containsAll(_objects.values)) {
      throw StateError('The authored hierarchy contains unregistered changes.');
    }
    final nodes = <StudioNode>[];
    for (final node in document.nodes) {
      final object = _objects[node.id]!;
      final color = node.color;
      if (object is Mesh) {
        if (!identical(object.geometry, _geometries[node.id]) ||
            object.geometry.capture().revision != _geometryRevisions[node.id] ||
            !identical(object.material, _materials[node.id])) {
          // The first slice edits transforms. Material authoring needs a fuller codec.
          throw StateError(
            'This document cannot save external geometry or material edits.',
          );
        }
      }
      nodes.add(
        StudioNode(
          id: node.id,
          label: node.label,
          kind: node.kind,
          parentId: object.parent == content ? null : idFor(object.parent),
          sourceId: node.sourceId,
          position: object.position,
          scale: object.scale,
          rotation: object.quaternion,
          visible: object.visible,
          size: node.size,
          color: color,
        ),
      );
    }
    return StudioDocument(
      id: document.id,
      title: document.title,
      nodes: nodes,
      camera: StudioCamera.capture(camera),
      review: engineering.document,
    );
  }
}
