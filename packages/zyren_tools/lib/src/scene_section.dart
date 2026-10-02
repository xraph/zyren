part of '../zyren_tools.dart';

const sceneSections = ServiceKey<SceneSectionPlugin>('zyren.sections');

/// A reversible section session. External edits take ownership immediately.
class SceneSectionPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.sections';

  /// Omit to keep section cuts uncapped. Caps use a separate opaque material.
  final MeshMaterial? capMaterial;
  final _targets = <Mesh>[];
  final _caps = <Mesh>[];
  final _issues = <Mesh, SectionCapIssue>{};
  Object? _capState;
  SceneSectionPlugin({this.capMaterial}) {
    if (capMaterial is ShaderMaterial ||
        capMaterial != null &&
            capMaterial!.alphaMode != MaterialAlphaMode.opaque) {
      throw ArgumentError('Caps require an opaque built-in material.');
    }
  }

  Map<Mesh, SectionCapIssue> get capIssues => Map.unmodifiable(_issues);
  List<Mesh> get capMeshes => List.unmodifiable(_caps);
  bool owns(Object3D object) => _caps.contains(object);

  /// Explicit targets keep editor helpers and unrelated objects out of caps.
  void setCapTargets(Iterable<Mesh> targets) {
    if (_context == null) {
      throw StateError('Attach sections before using them.');
    }
    final next = targets.toSet().toList();
    for (final target in next) {
      Object3D? root = target;
      while (root?.parent != null) {
        root = root!.parent;
      }
      if (!identical(root, _context!.scene) || owns(target)) {
        throw ArgumentError('Cap targets must be source meshes in this scene.');
      }
    }
    _targets
      ..clear()
      ..addAll(next);
    _capState = null;
    _syncCaps();
  }

  void _removeCaps() {
    for (final cap in _caps) {
      cap.parent?.remove(cap);
    }
    _caps.clear();
    _issues.clear();
    _capState = null;
  }

  void _syncCaps() {
    if (!isActive || capMaterial == null) {
      _removeCaps();
      return;
    }
    bool eligible(Mesh target) {
      Object3D? node = target;
      while (node != null) {
        if (!node.visible || !node.clippingEnabled) return false;
        if (identical(node, _context!.scene)) return true;
        node = node.parent;
      }
      return false;
    }

    final state = [
      _owned,
      for (final target in _targets)
        (target, target.geometry.revision, _world(target), eligible(target)),
    ];
    if (_capState is List && _sameCapState(_capState as List, state)) return;
    _removeCaps();
    for (final target in _targets.where(eligible)) {
      if (target is InstancedMesh ||
          target.material.primitiveKind != 0 ||
          !target.fragmentCoverage.isFull) {
        _issues[target] = SectionCapIssue.topology;
        continue;
      }
      final world = _world(target);
      // Keep the CPU intersection near the source before float32 conversion.
      final origin = _point(world, Vec3.zero);
      final relativeValues = [...world.storage];
      relativeValues[12] = relativeValues[13] = relativeValues[14] = 0;
      final relativeWorld = Mat4(relativeValues);
      final relativePlanes = [
        for (final plane in planes)
          ClippingPlane(
            normal: plane.normal,
            offset: plane.offset - plane.normal.dot(origin),
          ),
      ];
      final result = buildSectionCaps(
        target.geometry,
        relativeWorld,
        relativePlanes,
      );
      if (result.issue != null) {
        _issues[target] = result.issue!;
        continue;
      }
      final inverse = relativeWorld.inverted();
      final m = world.storage;
      for (final geometry in result.geometries) {
        final positions = <double>[], normals = <double>[];
        for (var i = 0; i < geometry.positions.length; i += 3) {
          positions.addAll(
            _point(inverse, Vec3.array(geometry.positions, i)).storage,
          );
          final n = Vec3.array(geometry.normals, i);
          normals.addAll(
            Vec3(
              m[0] * n.x + m[1] * n.y + m[2] * n.z,
              m[4] * n.x + m[5] * n.y + m[6] * n.z,
              m[8] * n.x + m[9] * n.y + m[10] * n.z,
            ).normalized().storage,
          );
        }
        final cap = target.add(
          Mesh(
              BufferGeometry(
                positions: positions,
                normals: normals,
                indices: _handedness(world) < 0
                    ? [
                        for (
                          var i = 0;
                          i < geometry.indices.length;
                          i += 3
                        ) ...[
                          geometry.indices[i],
                          geometry.indices[i + 2],
                          geometry.indices[i + 1],
                        ],
                      ]
                    : geometry.indices,
              ),
              capMaterial!,
              name: 'Section cap',
            )
            ..clippingEnabled = false
            ..outlineEnabled = false
            ..receiveShadow = false,
        );
        _caps.add(cap);
      }
    }
    _capState = state;
  }

  bool _sameCapState(List a, List b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => a[i] == b[i]);

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _releaseExternal();
    _syncCaps();
  }

  final _changes = StreamController<void>.broadcast();
  PluginContext? _context;
  List<ClippingPlane>? _previous, _owned;
  Stream<void> get changes => _changes.stream;
  bool get isActive =>
      _owned != null && identical(_context?.scene.clippingPlanes, _owned);
  List<ClippingPlane> get planes => isActive ? _owned! : const [];

  @override
  void attach(PluginContext context) {
    _context = context;
    context.provide(sceneSections, this);
    context.scope.listen(context.scene.changes, (_) => _releaseExternal());
  }

  void _releaseExternal() {
    if (_owned == null || isActive) return;
    _previous = _owned = null;
    _removeCaps();
    _changes.add(null);
  }

  /// Replaces this session's planes. An empty list restores the earlier scene.
  void setPlanes(List<ClippingPlane> value) {
    final scene =
        _context?.scene ??
        (throw StateError('Attach sections before using them.'));
    if (value.isEmpty) {
      clear();
      return;
    }
    if (value.length > 6) {
      throw ArgumentError('At most six section planes are supported.');
    }
    _releaseExternal();
    _previous ??= scene.clippingPlanes;
    scene.clippingPlanes = value;
    _owned = scene.clippingPlanes;
    _syncCaps();
    _changes.add(null);
  }

  void clear() {
    final context =
        _context ?? (throw StateError('Attach sections before using them.'));
    if (isActive) context.scene.clippingPlanes = _previous!;
    _previous = _owned = null;
    _removeCaps();
    _changes.add(null);
  }

  @override
  void detach(PluginContext context) {
    clear();
    _targets.clear();
    _context = null;
  }
}
