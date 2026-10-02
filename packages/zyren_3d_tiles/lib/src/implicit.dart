part of '../zyren_3d_tiles.dart';

/// Shared root definition. Bounds are derived from global coordinates, never
/// repeatedly subdivided, so deep trees do not accumulate rounding error.
final class _ImplicitSpec {
  final bool octree;
  final int levels, subtreeLevels, rootDepth;
  final Uri source;
  final String anchor, subtreeTemplate;
  final String? contentTemplate;
  final List<double> volume;
  final bool region;
  final Mat4 world;
  final double error;
  final TileRefinement refinement;
  final List<Uri> documents;
  final Tiles3DLimits limits;
  const _ImplicitSpec(
    this.octree,
    this.levels,
    this.subtreeLevels,
    this.rootDepth,
    this.source,
    this.anchor,
    this.subtreeTemplate,
    this.contentTemplate,
    this.volume,
    this.region,
    this.world,
    this.error,
    this.refinement,
    this.documents,
    this.limits,
  );

  static _ImplicitSpec parse(
    Map<String, dynamic> item,
    Uri source,
    Mat4 world,
    double error,
    TileRefinement refinement,
    String anchor,
    List<Uri> documents,
    int depth,
    Tiles3DLimits limits,
    AssetDecodeContext context,
  ) {
    if (item.containsKey('children') || item.containsKey('metadata')) {
      _invalid();
    }
    final json = _object(item['implicitTiling']);
    _extensions(json);
    final scheme = json['subdivisionScheme'];
    if (scheme != 'QUADTREE' && scheme != 'OCTREE') _invalid();
    final octree = scheme == 'OCTREE';
    final levels = _integer(json['availableLevels'], minimum: 1);
    final subtreeLevels = _integer(json['subtreeLevels'], minimum: 1);
    // Coordinates must remain exact in doubles used by bounds subdivision.
    if (levels > 52 || depth + levels - 1 > limits.maxDepth) _limit();
    var slots = 1;
    for (var i = 0; i < subtreeLevels; i++) {
      if (slots > limits.maxSubtreeTiles * 8 ~/ (octree ? 8 : 4)) _limit();
      slots *= octree ? 8 : 4;
    }
    final bounds = _object(item['boundingVolume']);
    if (bounds.containsKey('sphere')) _invalid();
    final region = bounds.containsKey('region');
    final volume = _numbers(bounds[region ? 'region' : 'box'], region ? 6 : 12);
    final subtree = _object(json['subtrees']);
    _extensions(subtree);
    String template(Object? value) {
      if (value is! String || value.isEmpty || value.length > 8192) _invalid();
      final keys = ['level', 'x', 'y', if (octree) 'z'];
      var example = value;
      for (final key in keys) {
        if (!example.contains('{$key}')) _invalid();
        example = example.replaceAll('{$key}', '0');
      }
      if (example.contains('{') || example.contains('}')) _invalid();
      context.resolveReference(example, relativeTo: source);
      return value;
    }

    String? contentTemplate;
    if (item.containsKey('content')) {
      final content = _object(item['content']);
      _extensions(content);
      if (content.containsKey('boundingVolume')) _invalid();
      contentTemplate = template(content['uri']);
    }
    return _ImplicitSpec(
      octree,
      levels,
      subtreeLevels,
      depth,
      source,
      anchor,
      template(subtree['uri']),
      contentTemplate,
      List.unmodifiable(volume),
      region,
      world,
      error,
      refinement,
      documents,
      limits,
    );
  }

  _ImplicitRef reference(int level, int x, int y, int z) =>
      _ImplicitRef(this, level, x, y, z);

  TileBounds3D bounds(int level, int x, int y, int z) {
    final n = math.pow(2, level).toDouble(), v = volume;
    if (region) {
      final width = v[2] < v[0] ? v[2] + 2 * math.pi - v[0] : v[2] - v[0];
      double longitude(double value) =>
          value > math.pi ? value - 2 * math.pi : value;
      return _bounds({
        'region': [
          longitude(v[0] + width * x / n),
          v[1] + (v[3] - v[1]) * y / n,
          longitude(v[0] + width * (x + 1) / n),
          v[1] + (v[3] - v[1]) * (y + 1) / n,
          octree ? v[4] + (v[5] - v[4]) * z / n : v[4],
          octree ? v[4] + (v[5] - v[4]) * (z + 1) / n : v[5],
        ],
      }, world);
    }
    final ax = Vec3.array(v, 3), ay = Vec3.array(v, 6), az = Vec3.array(v, 9);
    final center =
        Vec3.array(v) +
        ax * ((2 * x + 1) / n - 1) +
        ay * ((2 * y + 1) / n - 1) +
        (octree ? az * ((2 * z + 1) / n - 1) : Vec3.zero);
    final sx = ax / n, sy = ay / n, sz = octree ? az / n : az;
    return _bounds({
      'box': [
        center.x,
        center.y,
        center.z,
        sx.x,
        sx.y,
        sx.z,
        sy.x,
        sy.y,
        sy.z,
        sz.x,
        sz.y,
        sz.z,
      ],
    }, world);
  }
}

final class _ImplicitRef {
  final _ImplicitSpec spec;
  final int level, x, y, z;
  const _ImplicitRef(this.spec, this.level, this.x, this.y, this.z);
  String get id => '${spec.anchor}/implicit/$level/$x/$y/$z';
  Uri uri(String template, AssetDecodeContext context) =>
      context.resolveReference(
        template
            .replaceAll('{level}', '$level')
            .replaceAll('{x}', '$x')
            .replaceAll('{y}', '$y')
            .replaceAll('{z}', '$z'),
        relativeTo: spec.source,
      );
  TileNode3D node(
    AssetDecodeContext context, {
    String? id,
    bool subtree = true,
    bool content = false,
    List<TileNode3D> children = const [],
  }) => TileNode3D._(
    id ?? '${this.id}${subtree ? '/subtree' : ''}',
    spec.world,
    spec.bounds(level, x, y, z),
    spec.error / math.pow(2, level),
    spec.refinement,
    subtree
        ? uri(spec.subtreeTemplate, context)
        : content
        ? uri(spec.contentTemplate!, context)
        : null,
    children,
    spec.documents,
    spec.rootDepth + level,
    implicit: subtree ? this : null,
    implicitContent: !subtree,
  );
}

int _integer(Object? value, {int minimum = 0}) {
  if (value is! int || value < minimum) _invalid();
  return value;
}
