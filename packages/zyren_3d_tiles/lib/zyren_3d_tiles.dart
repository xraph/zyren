library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart'
    show Ellipsoid, Geodetic;

part 'src/tileset.dart';
part 'src/content.dart';
part 'src/external_content.dart';
part 'src/implicit.dart';
part 'src/subtree.dart';
part 'src/streamer.dart';
part 'src/plugin.dart';

abstract final class Tiles3D {
  static AssetRequest<Tileset3D> tileset(Uri uri, {Tiles3DLimits? limits}) =>
      AssetRequest(uri: uri, loader: _TilesetLoader(limits ?? Tiles3DLimits()));
  static AssetRequest<TileModel3D> content(
    Uri uri, {
    GltfOptions options = const GltfOptions(),
  }) => AssetRequest(uri: uri, loader: _ContentLoader(options));
}

Never _invalid() => throw AssetLoadException(
  AssetLoadError.invalidData,
  'Invalid 3D Tiles data.',
);
Never _unsupported() => throw AssetLoadException(
  AssetLoadError.unsupportedFeature,
  'This 3D Tiles feature is not supported.',
);
Never _limit() => throw AssetLoadException(
  AssetLoadError.limitExceeded,
  '3D Tiles exceeds its configured limits.',
);
Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) _invalid();
  return value.toDouble();
}

List<double> _numbers(Object? value, int length) {
  if (value is! List || value.length != length) _invalid();
  return value.map(_number).toList();
}

Map<String, dynamic> _json(Uint8List bytes, int maxBytes, int maxDepth) {
  if (bytes.length > maxBytes) _limit();
  var depth = 0, quoted = false, escaped = false;
  for (final byte in bytes) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (byte == 92) {
        escaped = true;
      } else if (byte == 34) {
        quoted = false;
      }
    } else if (byte == 34) {
      quoted = true;
    } else if (byte == 123 || byte == 91) {
      if (++depth > maxDepth) _limit();
    } else if (byte == 125 || byte == 93) {
      depth--;
    }
  }
  try {
    return _object(jsonDecode(utf8.decode(bytes)));
  } on FormatException {
    _invalid();
  }
}
