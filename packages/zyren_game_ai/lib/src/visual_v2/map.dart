part of '../../visual_v2.dart';

/// Published, permanent no-entry footprint. The conservative AABB may remove
/// extra walkable cells; it never publishes a private dynamic collider.
final class VisualNoEntryPolygon {
  final String sourceId;
  final List<Vec3> vertices;
  VisualNoEntryPolygon({required this.sourceId, required List<Vec3> vertices})
    : vertices = List.unmodifiable(vertices) {
    _name(sourceId);
    if (vertices.length < 3 || vertices.length > 16) {
      throw ArgumentError('No-entry polygon budget exceeded.');
    }
    for (final v in vertices) {
      _finite(v);
    }
    final firstY = vertices.first.y;
    var area = 0.0;
    for (var i = 0; i < vertices.length; i++) {
      final a = vertices[i], b = vertices[(i + 1) % vertices.length];
      if ((a.y - firstY).abs() > 1e-6) {
        throw ArgumentError('No-entry footprint must be planar.');
      }
      area += a.x * b.z - a.z * b.x;
    }
    if (area.abs() < 1e-6) {
      throw ArgumentError('No-entry footprint has no area.');
    }
  }
  Map<String, Object> toJson() => {
    'sourceId': sourceId,
    'vertices': vertices.map((v) => v.storage).toList(),
  };
  NavigationObstacle get obstacle => NavigationObstacle(
    'published:$sourceId',
    min: Vec3(
      vertices.map((v) => v.x).reduce(math.min),
      -10000,
      vertices.map((v) => v.z).reduce(math.min),
    ),
    max: Vec3(
      vertices.map((v) => v.x).reduce(math.max),
      10000,
      vertices.map((v) => v.z).reduce(math.max),
    ),
  );
}

/// The host supplies an explicit authored allowlist and its canonical SHA.
/// There is no scene traversal, physics enumeration or target resolver here.
final class VisualNavigationMap {
  final String hash;
  final BakedNavigationMesh mesh;
  final List<VisualNoEntryPolygon> noEntry;
  final List<NavigationGeometry> walkable;
  VisualNavigationMap._(this.hash, this.mesh, this.noEntry, this.walkable);
  static Map<String, Object> manifest({
    required List<NavigationGeometry> walkable,
    required List<VisualNoEntryPolygon> noEntry,
    required NavigationBakeSettings settings,
  }) => {
    'version': 2,
    'knowledge': 'published-authored-footprint-only',
    'settings': settings.json,
    'walkable': [
      for (final source in walkable)
        {
          'sourceId': source.sourceId,
          'revision': source.revision,
          'vertices': source.vertices.map((v) => v.storage).toList(),
          'triangles': source.triangles,
        },
    ],
    'noEntry': noEntry.map((v) => v.toJson()).toList(),
  };
  static String contentHash({
    required List<NavigationGeometry> walkable,
    required List<VisualNoEntryPolygon> noEntry,
    required NavigationBakeSettings settings,
  }) =>
      _pin(manifest(walkable: walkable, noEntry: noEntry, settings: settings));
  factory VisualNavigationMap.fromAuthored({
    required String expectedHash,
    required List<NavigationGeometry> walkable,
    required List<VisualNoEntryPolygon> noEntry,
    required NavigationBakeSettings settings,
  }) {
    _sha(expectedHash);
    final names = [
      ...walkable.map((v) => v.sourceId),
      ...noEntry.map((v) => v.sourceId),
    ];
    if (walkable.isEmpty ||
        names.length > 64 ||
        names.toSet().length != names.length ||
        settings.maxCells > 16384 ||
        walkable.fold<int>(0, (n, v) => n + v.triangles.length) > 8192) {
      throw ArgumentError('Authored map allowlist or budget differs.');
    }
    final hash = contentHash(
      walkable: walkable,
      noEntry: noEntry,
      settings: settings,
    );
    if (hash != expectedHash) throw ArgumentError('Authored map SHA differs.');
    return VisualNavigationMap._(
      hash,
      NavigationBaker(settings: settings).bake(walkable),
      List.unmodifiable(noEntry),
      List.unmodifiable(walkable),
    );
  }
  NavigationWorld _newWorld() =>
      NavigationWorld(mesh)
        ..setObstacles(noEntry.map((v) => v.obstacle).toList());
}
