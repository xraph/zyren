part of '../zyren_studio.dart';

/// Reconstructs owned content without serializing renderer helpers or runtime IDs.
final class StudioScene {
  StudioDocument _document;
  StudioDocument get document => _document;
  final StudioHistory history = StudioHistory();
  final StudioAssetScope? assets;
  final StudioExtensionRegistry extensionRegistry;
  final _assetMembers = <Object3D>{};
  final _assetSources = <Object3D, (String, String)>{};
  final _assetStates = <Object3D, String>{};
  final _recipes = <String, StudioMaterial>{};
  final Scene scene = Scene();
  final bool includeEnvironment;
  Group? _lighting;
  void _syncEnvironment() {
    _lighting?.parent?.remove(_lighting!);
    scene.background = Color3.hex(document.environment.background);
    if (includeEnvironment) _lighting = document.environment.apply(scene);
  }

  final Group content = Group(name: 'Authored scene');
  late final PerspectiveCamera camera = document.camera.createCamera();
  late final SceneToolsPlugin tools = _StudioTools(this);
  (String, String)? selectedSource;
  late final SceneEngineeringPlugin engineering = SceneEngineeringPlugin(
    document: _review(),
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
      'materials': _recipes.map((key, value) => MapEntry(key, value.toJson())),
      'review': engineering.document.encode(),
      'camera': StudioCamera.capture(camera).toJson(),
      'environment': document.environment.toJson(),
      'extensions': document.extensions.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    });
    if (_fingerprint != fingerprint) {
      _fingerprint = fingerprint;
      _revision++;
    }
    return _revision;
  }

  StudioScene(
    StudioDocument document, {
    this.assets,
    this.includeEnvironment = true,
    StudioExtensionRegistry? extensionRegistry,
  }) : _document = document,
       extensionRegistry = extensionRegistry ?? StudioExtensionRegistry() {
    this.extensionRegistry.validateDocument(document);
    _syncEnvironment();
    scene.add(content);
    for (final node in document.expandedNodes.values) {
      final Object3D object;
      if (node.kind.isPrimitive) {
        final geometry = studioPrimitiveGeometry(node.kind, node.size);
        _geometries[node.id] = geometry;
        final material = (node.material ?? StudioMaterial(color: node.color))
            .create();
        _materials[node.id] = material;
        _geometryRevisions[node.id] = geometry.capture().revision;
        object = Mesh(geometry, material, name: node.label);
      } else if (node.kind == StudioNodeKind.asset) {
        final descriptor = document.assets.singleWhere(
          (a) => a.id == node.assetId,
        );
        if (assets == null) {
          throw StateError('Asset ${descriptor.id} requires a loaded scope.');
        }
        final instance = assets!.instantiate(descriptor);
        object = Group(name: node.label)..add(instance.root);
        void visit(Object3D child) {
          _assetMembers.add(child);
          if (child is Mesh && node.material != null) {
            child.material = node.material!.create(imported: child.material);
          }
          _assetStates[child] = _assetState(child);
          for (final nested in child.children) {
            visit(nested);
          }
        }

        visit(instance.root);
        for (final source in instance.sources.entries) {
          _assetSources[source.value] = (node.id, source.key);
        }
      } else {
        object = Group(name: node.label);
      }
      object.position = node.position;
      object.scale = node.scale;
      object.quaternion = node.rotation;
      object.visible = node.visible;
      _objects[node.id] = object;
      if (node.material != null) _recipes[node.id] = node.material!;
    }
    for (final node in document.expandedNodes.values) {
      (_objects[node.parentId] ?? content).add(_objects[node.id]!);
    }
    engineering.document.encode();
  }

  Map<String, Object3D> get objects => Map.unmodifiable(_objects);
  String? idFor(Object3D? object) {
    for (
      Object3D? current = object;
      current != null;
      current = current.parent
    ) {
      for (final entry in _objects.entries) {
        if (identical(entry.value, current)) return entry.key;
      }
      if (current != object && !_assetMembers.contains(current)) break;
      if (current == object && !_assetMembers.contains(current)) break;
    }
    return null;
  }

  /// Instance identity and source provenance remain separate in imported meshes.
  (String, String)? sourceFor(Object3D object) {
    for (
      Object3D? current = object;
      current != null;
      current = current.parent
    ) {
      if (_assetSources[current] case final source?) return source;
    }
    final id = idFor(object);
    final source = document.expandedNodes[id]?.sourceId;
    return id == null || source == null ? null : (id, source);
  }

  String reviewIdFor(String nodeId, String sourceId) =>
      document.prefabOwners.containsKey(nodeId) ||
          document.expandedNodes[nodeId]?.assetId != null
      ? '$nodeId:$sourceId'
      : sourceId;

  EngineeringDocument _review() {
    final records = {...document.review.objects};
    void record(String nodeId, String sourceId) {
      final id = reviewIdFor(nodeId, sourceId);
      final source = records[sourceId];
      records.putIfAbsent(
        id,
        () => EngineeringObject(
          id: id,
          label: source?.label ?? sourceId,
          properties: {
            ...?source?.properties,
            'sourceId': sourceId,
            'instanceId': nodeId,
          },
        ),
      );
    }

    for (final node in document.expandedNodes.values) {
      if (node.sourceId != null) record(node.id, node.sourceId!);
    }
    for (final source in _assetSources.values) {
      record(source.$1, source.$2);
    }
    return EngineeringDocument(
      id: document.id,
      objects: records.values,
      annotations: document.review.annotations.values,
    );
  }

  /// Call after every engine attachment, including native renderer recovery.
  void bindReview() {
    for (final node in document.expandedNodes.values) {
      if (node.sourceId != null) {
        engineering.bind(
          reviewIdFor(node.id, node.sourceId!),
          _objects[node.id]!,
        );
      }
    }
    for (final entry in _assetSources.entries) {
      engineering.bind(reviewIdFor(entry.value.$1, entry.value.$2), entry.key);
    }
  }

  void edit(void Function() action) {
    final before = capture();
    action();
    recordEdit(before);
  }

  void recordEdit(StudioDocument before) {
    history.record(before, capture());
    tools.clearHistory();
  }

  bool get canUndo => history.canUndo || tools.canUndo;
  bool get canRedo => history.canRedo || tools.canRedo;
  bool undo() =>
      history.canUndo ? history.undo(capture(), _apply) : tools.undo();
  bool redo() =>
      history.canRedo ? history.redo(capture(), _apply) : tools.redo();

  /// Reconstruct first, then swap owned content while keeping the renderer alive.
  void apply(StudioDocument next) => edit(() => _apply(next));

  void _apply(StudioDocument next) {
    capture();
    extensionRegistry.validateEdit(document, next);
    if (next.id != document.id || engineering.isBusy) {
      throw StateError('Document identity changed or review storage is busy.');
    }
    Map<String, Object?> recipe(StudioNode node) => node.toJson()
      ..remove('position')
      ..remove('rotation')
      ..remove('scale')
      ..remove('visible')
      ..remove('overrides');
    final sameRecipes =
        jsonEncode(document.assets.map((a) => a.toJson()).toList()) ==
            jsonEncode(next.assets.map((a) => a.toJson()).toList()) &&
        jsonEncode(
              document.expandedNodes.map(
                (id, node) => MapEntry(id, recipe(node)),
              ),
            ) ==
            jsonEncode(
              next.expandedNodes.map((id, node) => MapEntry(id, recipe(node))),
            );
    if (sameRecipes) {
      engineering.replaceDocument(next.review, expected: engineering.document);
      scene.batch(() {
        for (final node in next.expandedNodes.values) {
          final object = _objects[node.id]!;
          object.position = node.position;
          object.scale = node.scale;
          object.quaternion = node.rotation;
          object.visible = node.visible;
        }
        final environmentChanged =
            jsonEncode(document.environment.toJson()) !=
            jsonEncode(next.environment.toJson());
        _document = next;
        if (environmentChanged) _syncEnvironment();
      });
      if (engineering.isAttached) bindReview();
      return;
    }
    final rebuilt = StudioScene(
      next,
      assets: assets,
      includeEnvironment: includeEnvironment,
      extensionRegistry: extensionRegistry,
    );
    final resolved = rebuilt.capture();
    final selectedId = idFor(tools.selected);
    final previousSource = selectedSource;
    if (engineering.isAttached) {
      for (final id in engineering.document.objects.keys) {
        engineering.unbind(id);
      }
    }
    engineering.replaceDocument(
      resolved.review,
      expected: engineering.document,
    );
    if (tools.selected != null) tools.select(null);
    tools.clearHistory();
    scene.batch(() {
      for (final child in content.children.toList()) {
        content.remove(child);
      }
      for (final child in rebuilt.content.children.toList()) {
        content.add(child);
      }
      _objects
        ..clear()
        ..addAll(rebuilt._objects);
      _geometries
        ..clear()
        ..addAll(rebuilt._geometries);
      _materials
        ..clear()
        ..addAll(rebuilt._materials);
      _geometryRevisions
        ..clear()
        ..addAll(rebuilt._geometryRevisions);
      _assetMembers
        ..clear()
        ..addAll(rebuilt._assetMembers);
      _assetSources
        ..clear()
        ..addAll(rebuilt._assetSources);
      _assetStates
        ..clear()
        ..addAll(rebuilt._assetStates);
      _recipes
        ..clear()
        ..addAll(rebuilt._recipes);
      _document = resolved;
      _syncEnvironment();
    });
    if (engineering.isAttached) bindReview();
    if (_objects[selectedId] case final selected?) {
      final sourceObject = _assetSources.entries
          .where((entry) => entry.value == previousSource)
          .firstOrNull
          ?.key;
      tools.select(sourceObject ?? selected);
    }
  }

  /// Supported edits replace immutable material values through one owned path.
  void setMaterial(String id, StudioMaterial recipe) {
    capture();
    final object = _objects[id];
    if (object == null ||
        document.expandedNodes[id]!.kind == StudioNodeKind.group ||
        document.expandedNodes[id]!.kind == StudioNodeKind.prefab) {
      throw ArgumentError(
        'Select a primitive or imported asset to edit its material.',
      );
    }
    void apply(Object3D object) {
      if (object is Mesh) {
        object.material = recipe.create(imported: object.material);
        if (_assetMembers.contains(object)) {
          _assetStates[object] = _assetState(object);
        } else {
          _materials[id] = object.material;
        }
      }
      for (final child in object.children) {
        if (_assetMembers.contains(child)) apply(child);
      }
    }

    apply(object);
    _recipes[id] = recipe;
  }

  String _assetState(Object3D object) => jsonEncode([
    object.parent?.id,
    object.localMatrix.storage,
    object.visible,
    if (object is Mesh) object.geometry.capture().revision,
    if (object is Mesh) identityHashCode(object.geometry),
    if (object is Mesh) identityHashCode(object.material),
  ]);

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
    if (members.length != _objects.length + _assetMembers.length ||
        !members.containsAll(_objects.values) ||
        !members.containsAll(_assetMembers)) {
      throw StateError('The authored hierarchy contains unregistered changes.');
    }
    for (final entry in _assetStates.entries) {
      if (_assetState(entry.key) != entry.value) {
        throw StateError(
          'Imported asset structure was changed outside authoring.',
        );
      }
    }
    final effective = <String, StudioNode>{};
    for (final node in document.expandedNodes.values) {
      final object = _objects[node.id]!;
      if (object is Mesh) {
        if (!identical(object.geometry, _geometries[node.id]) ||
            object.geometry.capture().revision != _geometryRevisions[node.id] ||
            !identical(object.material, _materials[node.id])) {
          throw StateError(
            'This document cannot save external geometry or material edits.',
          );
        }
      }
      if (object.parent != content && !_objects.containsValue(object.parent)) {
        throw StateError(
          'Authored nodes cannot be parented inside imported assets.',
        );
      }
      final parentId = object.parent == content ? null : idFor(object.parent);
      if (document.prefabOwners.containsKey(node.id) &&
          parentId != node.parentId) {
        throw StateError('Prefab hierarchy edits must update the definition.');
      }
      effective[node.id] = node.copyWith(
        parentId: parentId,
        clearParent: parentId == null,
        position: object.position,
        scale: object.scale,
        rotation: object.quaternion,
        visible: object.visible,
        material: _recipes[node.id],
      );
    }
    final nodes = <StudioNode>[];
    for (final node in document.nodes) {
      final overrides = {...node.overrides};
      for (final entry in document.prefabOwners.entries.where(
        (e) => e.value == node.id,
      )) {
        final changed = effective[entry.key]!;
        final original = document.expandedNodes[entry.key]!;
        if (jsonEncode(changed.toJson()) != jsonEncode(original.toJson())) {
          overrides[entry.key.substring(node.id.length + 1)] = StudioOverride(
            position: changed.position,
            scale: changed.scale,
            rotation: changed.rotation,
            visible: changed.visible,
            material: changed.material,
          );
        }
      }
      nodes.add(effective[node.id]!.copyWith(overrides: overrides));
    }
    return document.copyWith(
      nodes: nodes,
      camera: StudioCamera.capture(camera),
      review: engineering.document,
    );
  }
}

/// Keep gizmos on authored instances while retaining picked source provenance.
final class _StudioTools extends SceneToolsPlugin {
  final StudioScene studio;
  _StudioTools(this.studio) : super(highlightSelection: false);

  @override
  void select(Object3D? object) {
    final id = studio.idFor(object);
    final source = object == null ? null : studio.sourceFor(object);
    super.select(id == null ? null : studio.objects[id]);
    studio.selectedSource = source;
  }
}
