part of '../zyren_3d_tiles.dart';

final class Tiles3DLimits {
  final int maxManifestBytes, maxTiles, maxDepth, maxSubtreeTiles;
  Tiles3DLimits({
    this.maxManifestBytes = 4 * 1024 * 1024,
    this.maxTiles = 4096,
    this.maxDepth = 64,
    this.maxSubtreeTiles = 8192,
  }) {
    RangeError.checkValueInInterval(maxManifestBytes, 1, 16 * 1024 * 1024);
    RangeError.checkValueInInterval(maxTiles, 1, 32768);
    RangeError.checkValueInInterval(maxDepth, 1, 128);
    RangeError.checkValueInInterval(maxSubtreeTiles, 1, 32768);
  }
}

enum TileRefinement { add, replace }

/// Conservative world-space sphere. Region bounds are already in WGS84 ECEF.
final class TileBounds3D {
  final Vec3 center;
  final double radius;
  const TileBounds3D._(this.center, this.radius);
  double screenError(double error, Camera camera, ViewportMetrics viewport) {
    if (camera is OrthographicCamera) {
      return error *
          viewport.height *
          camera.zoom /
          (camera.top - camera.bottom);
    }
    if (camera is PerspectiveCamera) {
      return error *
          viewport.height *
          camera.zoom /
          (2 *
              math.tan(camera.fieldOfView / 2) *
              math.max(.001, (center - camera.position).length - radius));
    }
    throw UnsupportedError(
      '3D Tiles requires a perspective or orthographic camera.',
    );
  }

  bool isVisible(Camera camera, ViewportMetrics viewport) {
    final delta = center - camera.position,
        forward = (camera.target - camera.position).normalized();
    final right = forward.cross(camera.up).normalized(),
        up = right.cross(forward);
    final x = delta.dot(right), y = delta.dot(up), z = delta.dot(forward);
    if (camera is PerspectiveCamera) {
      if (z + radius < camera.near || z - radius > camera.far) return false;
      final ty = math.tan(camera.fieldOfView / 2) / camera.zoom,
          tx = ty * viewport.aspect;
      return x.abs() <= z * tx + radius * math.sqrt(1 + tx * tx) &&
          y.abs() <= z * ty + radius * math.sqrt(1 + ty * ty);
    }
    if (camera is OrthographicCamera) {
      return z + radius >= camera.near &&
          z - radius <= camera.far &&
          (x - (camera.left + camera.right) / 2).abs() <=
              (camera.right - camera.left) / (2 * camera.zoom) + radius &&
          (y - (camera.top + camera.bottom) / 2).abs() <=
              (camera.top - camera.bottom) / (2 * camera.zoom) + radius;
    }
    throw UnsupportedError(
      '3D Tiles requires a perspective or orthographic camera.',
    );
  }
}

final class TileNode3D {
  final String id;
  final Mat4 transform;
  final TileBounds3D bounds;
  final double geometricError;
  final TileRefinement refinement;
  final Uri? contentUri;
  final List<TileNode3D> children;
  final List<Uri> _documentAncestors;
  final int _depth;
  final _ImplicitRef? _implicit;
  final bool _implicitContent;
  TileNode3D._(
    this.id,
    this.transform,
    this.bounds,
    this.geometricError,
    this.refinement,
    this.contentUri,
    List<TileNode3D> children,
    this._documentAncestors,
    this._depth, {
    _ImplicitRef? implicit,
    bool implicitContent = false,
  }) : children = List.unmodifiable(children),
       _implicit = implicit,
       _implicitContent = implicitContent;
}

final class Tileset3D {
  final TileNode3D root;
  final Uri sourceUri;
  final String version;
  final int tileCount;
  final double geometricError;
  final Tiles3DLimits _limits;
  const Tileset3D._(
    this.root,
    this.sourceUri,
    this.version,
    this.tileCount,
    this.geometricError,
    this._limits,
  );
}

class _TilesetLoader extends AssetLoader<Tileset3D> {
  final Tiles3DLimits limits;
  final TileNode3D? referringNode;
  const _TilesetLoader(this.limits, {this.referringNode});
  @override
  Future<DecodedAsset<Tileset3D>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final referring = referringNode;
    final ancestors = referring?._documentAncestors ?? const <Uri>[];
    if (ancestors.contains(source.effectiveUri)) _invalid();
    if (referring != null && referring._depth >= limits.maxDepth) _limit();
    final documents = List<Uri>.unmodifiable([
      ...ancestors,
      source.effectiveUri,
    ]);
    final json = _json(
      source.bytes,
      limits.maxManifestBytes,
      limits.maxDepth * 2 + 16,
    );
    _extensions(json);
    final asset = _object(json['asset']);
    if (!['1.0', '1.1'].contains(asset['version']) ||
        asset.containsKey('gltfUpAxis') && asset['gltfUpAxis'] != 'Y') {
      _unsupported();
    }
    final geometricError = _number(json['geometricError']);
    if (geometricError < 0) _invalid();
    var count = 0;
    TileNode3D node(
      Object? value,
      Mat4 parent,
      String id,
      int depth,
      TileRefinement? inherited,
    ) {
      context.cancellation.throwIfCancelled();
      if (++count > limits.maxTiles || depth > limits.maxDepth) _limit();
      context.reserveDecodedBytes(512);
      final item = _object(value);
      _extensions(item);
      for (final key in ['contents', 'viewerRequestVolume']) {
        if (item.containsKey(key)) _unsupported();
      }
      final refine = item['refine'];
      final refinement = refine == null
          ? inherited
          : switch (refine) {
              'ADD' => TileRefinement.add,
              'REPLACE' => TileRefinement.replace,
              _ => null,
            };
      if (refinement == null) _invalid();
      final local = item.containsKey('transform')
          ? _affine(_numbers(item['transform'], 16))
          : Mat4.identity();
      final world = _affine((parent * local).storage);
      final error = _number(item['geometricError']) * _scale(world);
      if (error < 0 || !error.isFinite) _invalid();
      final bounds = _bounds(_object(item['boundingVolume']), world);
      if (item.containsKey('implicitTiling')) {
        final spec = _ImplicitSpec.parse(
          item,
          source.effectiveUri,
          world,
          error,
          refinement,
          id,
          documents,
          depth,
          limits,
          context,
        );
        return spec.reference(0, 0, 0, 0).node(context, id: id);
      }
      Uri? uri;
      if (item.containsKey('content')) {
        final content = _object(item['content']);
        _extensions(content);
        final reference = content['uri'] ?? content['url'];
        if (reference is! String ||
            reference.isEmpty ||
            reference.length > 8192) {
          _invalid();
        }
        uri = context.resolveReference(
          reference,
          relativeTo: source.effectiveUri,
        );
        if (content.containsKey('boundingVolume')) {
          _bounds(_object(content['boundingVolume']), world);
        }
      }
      final children = item['children'] ?? [];
      if (children is! List || children.length > limits.maxTiles - count) {
        _limit();
      }
      return TileNode3D._(
        id,
        world,
        bounds,
        error,
        refinement,
        uri,
        [
          for (var i = 0; i < children.length; i++)
            node(children[i], world, '$id/$i', depth + 1, refinement),
        ],
        documents,
        depth,
      );
    }

    final root = node(
      json['root'],
      referring?.transform ?? Mat4.identity(),
      referring == null ? '0' : '${referring.id}/external',
      (referring?._depth ?? 0) + 1,
      referring?.refinement,
    );
    final result = Tileset3D._(
      root,
      source.effectiveUri,
      asset['version'] as String,
      count,
      geometricError,
      limits,
    );
    return DecodedAsset(create: () => result, release: (_) {});
  }
}

void _extensions(Map<String, dynamic> json) {
  for (final key in ['extensionsRequired', 'extensions']) {
    final value = json[key];
    if (value != null &&
        (value is! List && value is! Map ||
            (value as dynamic).isNotEmpty as bool)) {
      _unsupported();
    }
  }
}

Mat4 _affine(List<double> values) {
  if (values[3] != 0 ||
      values[7] != 0 ||
      values[11] != 0 ||
      values[15] != 1 ||
      values.any((v) => !v.isFinite || v.abs() > 1e15)) {
    _invalid();
  }
  final result = Mat4(values);
  try {
    result.inverted();
  } on ArgumentError {
    _invalid();
  }
  return result;
}

Vec3 _point(Mat4 m, Vec3 p, {bool direction = false}) {
  final a = m.storage;
  return Vec3(
    a[0] * p.x + a[4] * p.y + a[8] * p.z + (direction ? 0 : a[12]),
    a[1] * p.x + a[5] * p.y + a[9] * p.z + (direction ? 0 : a[13]),
    a[2] * p.x + a[6] * p.y + a[10] * p.z + (direction ? 0 : a[14]),
  );
}

double _scale(Mat4 m) {
  final a = m.storage;
  var rows = 0.0, columns = 0.0;
  for (var i = 0; i < 3; i++) {
    rows = math.max(rows, a[i].abs() + a[i + 4].abs() + a[i + 8].abs());
    columns = math.max(
      columns,
      a[i * 4].abs() + a[i * 4 + 1].abs() + a[i * 4 + 2].abs(),
    );
  }
  return math.sqrt(rows * columns);
}

TileBounds3D _bounds(Map<String, dynamic> json, Mat4 world) {
  _extensions(json);
  if (['sphere', 'box', 'region'].where(json.containsKey).length != 1) {
    _invalid();
  }
  late Vec3 center;
  late double radius;
  if (json.containsKey('sphere')) {
    final values = _numbers(json['sphere'], 4);
    if (values[3] < 0) _invalid();
    center = _point(world, Vec3.array(values));
    radius = values[3] * _scale(world);
  } else if (json.containsKey('box')) {
    final values = _numbers(json['box'], 12);
    center = _point(world, Vec3.array(values));
    radius = 0;
    for (var i = 3; i < 12; i += 3) {
      radius += _point(world, Vec3.array(values, i), direction: true).length;
    }
  } else {
    final v = _numbers(json['region'], 6);
    if (v[0].abs() > math.pi ||
        v[2].abs() > math.pi ||
        v[1] < -math.pi / 2 ||
        v[3] > math.pi / 2 ||
        v[3] < v[1] ||
        v[5] < v[4] ||
        v[4].abs() > 1e8 ||
        v[5].abs() > 1e8) {
      _invalid();
    }
    final width = v[2] < v[0] ? v[2] + 2 * math.pi - v[0] : v[2] - v[0];
    center = Geodetic(v[0] + width / 2, (v[1] + v[3]) / 2).toEcef();
    const e = Ellipsoid.wgs84;
    radius =
        e.maximumRadius *
            e.maximumRadius /
            e.minimumRadius *
            (width + v[3] - v[1]) /
            2 +
        math.max(v[4].abs(), v[5].abs()) +
        1;
  }
  if (!center.isFinite || !radius.isFinite || radius < 0) _invalid();
  return TileBounds3D._(center, radius);
}
