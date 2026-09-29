import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../tiling.dart';

/// Whether a source knows that a tile exists. Unknown requires ancestor metadata.
enum TerrainAvailability { available, unavailable, unknown }

/// North-first water coverage: 0 is land, 255 is water, with soft edges allowed.
final class TerrainWaterMask {
  final Uint8List bytes;
  TerrainWaterMask(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (bytes.length != 1 && bytes.length != 256 * 256) {
      throw ArgumentError('Water masks require one byte or a 256-square grid.');
    }
  }
  int get size => bytes.length == 1 ? 1 : 256;
}

/// Inclusive absolute TMS coordinates at one level.
final class TerrainAvailabilityRange {
  final int startX, startY, endX, endY;
  TerrainAvailabilityRange(this.startX, this.startY, this.endX, this.endY) {
    if (startX < 0 ||
        startY < 0 ||
        endX < startX ||
        endY < startY ||
        endX >= 1 << 31 ||
        endY >= 1 << 30) {
      throw ArgumentError('Invalid terrain availability range.');
    }
  }
  bool contains(TileCoordinate tile) =>
      tile.x >= startX && tile.x <= endX && tile.y >= startY && tile.y <= endY;
  @override
  bool operator ==(Object other) =>
      other is TerrainAvailabilityRange &&
      startX == other.startX &&
      startY == other.startY &&
      endX == other.endX &&
      endY == other.endY;
  @override
  int get hashCode => Object.hash(startX, startY, endX, endY);
}

/// Level zero in [levels] describes children of the containing tile.
final class TerrainAvailabilityMetadata {
  final List<List<TerrainAvailabilityRange>> levels;
  TerrainAvailabilityMetadata(List<List<TerrainAvailabilityRange>> levels)
    : levels = List.unmodifiable(
        levels.map(
          (level) => List<TerrainAvailabilityRange>.unmodifiable(level),
        ),
      ) {
    if (levels.length > 30 || rangeCount > 4096) {
      throw ArgumentError('Terrain availability exceeds supported sizes.');
    }
  }
  int get rangeCount => levels.fold(0, (n, level) => n + level.length);
  int get decodedBytes => levels.length * 8 + rangeCount * 32;
}

TerrainAvailabilityMetadata decodeTerrainAvailability(
  Uint8List bytes, {
  required int maxBytes,
  required int maxRanges,
}) {
  final json = bytes.isEmpty
      ? <String, dynamic>{}
      : terrainJson(bytes, maxBytes);
  final values = json['available'] ?? [];
  if (values is! List || values.length > 30) terrainInvalid();
  var count = 0;
  final levels = <List<TerrainAvailabilityRange>>[];
  for (final level in values) {
    if (level is! List) terrainInvalid();
    count += level.length;
    if (count > maxRanges) terrainLimit();
    final ranges = <TerrainAvailabilityRange>[];
    for (final value in level) {
      if (value is! Map<String, dynamic>) terrainInvalid();
      final fields = [
        'startX',
        'startY',
        'endX',
        'endY',
      ].map((k) => value[k]).toList();
      if (fields.any((n) => n is! int)) terrainInvalid();
      try {
        ranges.add(
          TerrainAvailabilityRange(
            fields[0] as int,
            fields[1] as int,
            fields[2] as int,
            fields[3] as int,
          ),
        );
      } on ArgumentError {
        terrainInvalid();
      }
    }
    levels.add(ranges);
  }
  return TerrainAvailabilityMetadata(levels);
}

/// Bounds nesting and rejects duplicate keys before constructing a JSON tree.
Map<String, dynamic> terrainJson(Uint8List bytes, int maxBytes) {
  if (bytes.length > maxBytes) terrainLimit();
  try {
    final stack = <(int, Set<String>)>[];
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b == 34) {
        final start = i;
        for (i++; i < bytes.length && bytes[i] != 34; i++) {
          if (bytes[i] == 92) i++;
        }
        if (i >= bytes.length) terrainInvalid();
        var next = i + 1;
        while (next < bytes.length && [32, 9, 10, 13].contains(bytes[next])) {
          next++;
        }
        if (next < bytes.length &&
            bytes[next] == 58 &&
            stack.isNotEmpty &&
            stack.last.$1 == 123) {
          final key =
              jsonDecode(
                    utf8.decode(Uint8List.sublistView(bytes, start, i + 1)),
                  )
                  as String;
          if (!stack.last.$2.add(key)) terrainInvalid();
        }
      } else if (b == 123 || b == 91) {
        stack.add((b, <String>{}));
        if (stack.length > 16) terrainLimit();
      } else if (b == 125 || b == 93) {
        if (stack.isEmpty || stack.removeLast().$1 != (b == 125 ? 123 : 91)) {
          terrainInvalid();
        }
      }
    }
    if (stack.isNotEmpty) terrainInvalid();
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) terrainInvalid();
    return json;
  } on FormatException {
    terrainInvalid();
  }
}

Never terrainInvalid() => throw AssetLoadException(
  AssetLoadError.invalidData,
  'Invalid terrain extension data.',
);
Never terrainLimit() => throw AssetLoadException(
  AssetLoadError.limitExceeded,
  'Terrain extension exceeds its limits.',
);
