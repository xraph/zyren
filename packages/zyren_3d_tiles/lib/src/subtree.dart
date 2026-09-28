part of '../zyren_3d_tiles.dart';

Future<Tileset3D> _decodeSubtree(
  _ImplicitRef ref,
  ResolvedSource source,
  AssetDecodeContext context,
) async {
  final spec = ref.spec, limits = spec.limits, bytes = source.bytes;
  Uint8List jsonBytes = bytes;
  Uint8List? binary;
  if (bytes.length >= 4 &&
      ByteData.sublistView(bytes).getUint32(0, Endian.little) == 0x74627573) {
    if (bytes.length < 24) _invalid();
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(4, Endian.little) != 1) _unsupported();
    // Reject the high words before arithmetic, including signed-u64 overflow.
    if (header.getUint32(12, Endian.little) != 0 ||
        header.getUint32(20, Endian.little) != 0) {
      _limit();
    }
    final jsonLength = header.getUint32(8, Endian.little);
    final binaryLength = header.getUint32(16, Endian.little);
    if (jsonLength == 0 ||
        jsonLength % 8 != 0 ||
        binaryLength % 8 != 0 ||
        jsonLength > bytes.length - 24 ||
        binaryLength != bytes.length - 24 - jsonLength) {
      _invalid();
    }
    jsonBytes = Uint8List.sublistView(bytes, 24, 24 + jsonLength);
    binary = Uint8List.sublistView(bytes, 24 + jsonLength);
  }
  final json = _json(jsonBytes, limits.maxManifestBytes, 32);
  _extensions(json);
  for (final key in ['tileMetadata', 'contentMetadata', 'propertyTables']) {
    if (json.containsKey(key)) _unsupported();
  }
  final buffersJson = json['buffers'] ?? [];
  final viewsJson = json['bufferViews'] ?? [];
  if (buffersJson is! List || viewsJson is! List) _invalid();
  if (buffersJson.length > context.limits.maxSources ||
      viewsJson.length > limits.maxSubtreeTiles * 4) {
    _limit();
  }
  final buffers = <Uint8List>[];
  for (var i = 0; i < buffersJson.length; i++) {
    final item = _object(buffersJson[i]);
    _extensions(item);
    final length = _integer(item['byteLength'], minimum: 1);
    if (length > context.limits.maxSourceBytes) _limit();
    context.reserveDecodedBytes(length);
    final uri = item['uri'];
    if (uri == null) {
      if (i != 0 ||
          binary == null ||
          length > binary.length ||
          binary.length - length > 7) {
        _invalid();
      }
      if (binary.skip(length).any((b) => b != 0)) _invalid();
      buffers.add(Uint8List.sublistView(binary, 0, length));
    } else {
      if (uri is! String ||
          uri.isEmpty ||
          uri.length > 8192 ||
          Uri.parse(uri).scheme == 'data') {
        _invalid();
      }
      final data = await context.readReference(
        uri,
        relativeTo: source.effectiveUri,
      );
      if (data.bytes.length != length) _invalid();
      buffers.add(data.bytes);
    }
  }
  if (binary != null &&
      binary.isNotEmpty &&
      (buffersJson.isEmpty || _object(buffersJson.first)['uri'] != null)) {
    _invalid();
  }
  final views = <Uint8List>[];
  for (final value in viewsJson) {
    final item = _object(value);
    _extensions(item);
    final buffer = _integer(item['buffer']);
    final offset = _integer(item['byteOffset'] ?? 0);
    final length = _integer(item['byteLength'], minimum: 1);
    if (buffer >= buffers.length ||
        offset % 8 != 0 ||
        offset > buffers[buffer].length ||
        length > buffers[buffer].length - offset) {
      _invalid();
    }
    views.add(Uint8List.sublistView(buffers[buffer], offset, offset + length));
  }
  final branch = spec.octree ? 8 : 4;
  var boundaryCount = 1, tileCount = 0;
  for (var i = 0; i < spec.subtreeLevels; i++) {
    tileCount += boundaryCount;
    boundaryCount *= branch;
  }
  final tiles = _Availability.parse(json['tileAvailability'], tileCount, views);
  final children = _Availability.parse(
    json['childSubtreeAvailability'],
    boundaryCount,
    views,
  );
  final contentJson = json['contentAvailability'];
  late final _Availability content;
  if (spec.contentTemplate == null) {
    if (contentJson != null) _invalid();
    content = const _Availability(0, null, 0);
  } else {
    if (contentJson is! List || contentJson.length != 1) _invalid();
    content = _Availability.parse(contentJson.single, tileCount, views);
  }
  if (!tiles.at(0)) _invalid();
  if (tiles.count + children.count > limits.maxSubtreeTiles) _limit();
  // Validate all availability before creating nodes or publishing any content.
  var offset = 0, width = 1;
  for (var depth = 0; depth < spec.subtreeLevels; depth++) {
    for (var i = offset; i < offset + width; i++) {
      if (i % 1024 == 0) context.cancellation.throwIfCancelled();
      final present = tiles.at(i);
      if (present &&
          (ref.level + depth >= spec.levels ||
              i > 0 && !tiles.at((i - 1) ~/ branch))) {
        _invalid();
      }
      if (content.at(i) && !present) _invalid();
    }
    offset += width;
    width *= branch;
  }
  final lastOffset = tileCount - boundaryCount ~/ branch;
  for (var i = 0; i < boundaryCount; i++) {
    if (i % 1024 == 0) context.cancellation.throwIfCancelled();
    if (children.at(i) &&
        (ref.level + spec.subtreeLevels >= spec.levels ||
            !tiles.at(lastOffset + i ~/ branch))) {
      _invalid();
    }
  }
  final count = tiles.count + children.count;
  context.reserveDecodedBytes(count * 512);
  TileNode3D build(
    _ImplicitRef coordinate,
    int depth,
    int index,
    int levelOffset,
  ) {
    final descendants = <TileNode3D>[];
    if (depth + 1 < spec.subtreeLevels) {
      final nextOffset = levelOffset + _power(branch, depth);
      for (var child = 0; child < branch; child++) {
        final nextIndex = index * branch + child;
        if (tiles.at(nextOffset + nextIndex)) {
          descendants.add(
            build(
              _nextImplicit(coordinate, child),
              depth + 1,
              nextIndex,
              nextOffset,
            ),
          );
        }
      }
    } else {
      for (var child = 0; child < branch; child++) {
        if (children.at(index * branch + child)) {
          descendants.add(_nextImplicit(coordinate, child).node(context));
        }
      }
    }
    return coordinate.node(
      context,
      subtree: false,
      content: content.at(levelOffset + index),
      children: descendants,
    );
  }

  return Tileset3D._(
    build(ref, 0, 0, 0),
    spec.source,
    '1.1',
    count,
    spec.error / math.pow(2, ref.level),
    limits,
  );
}

_ImplicitRef _nextImplicit(_ImplicitRef parent, int child) =>
    parent.spec.reference(
      parent.level + 1,
      parent.x * 2 + (child & 1),
      parent.y * 2 + ((child >> 1) & 1),
      parent.spec.octree ? parent.z * 2 + ((child >> 2) & 1) : 0,
    );
int _power(int base, int exponent) {
  var value = 1;
  for (var i = 0; i < exponent; i++) {
    value *= base;
  }
  return value;
}

final class _Availability {
  final int? constant;
  final Uint8List? bits;
  final int count;
  const _Availability(this.constant, this.bits, this.count);
  bool at(int index) => constant != null
      ? constant == 1
      : bits![index ~/ 8] & (1 << (index % 8)) != 0;
  static _Availability parse(Object? value, int length, List<Uint8List> views) {
    final item = _object(value);
    _extensions(item);
    if (item.containsKey('constant') == item.containsKey('bitstream')) {
      _invalid();
    }
    late final _Availability result;
    if (item.containsKey('constant')) {
      final constant = _integer(item['constant']);
      if (constant > 1) _invalid();
      result = _Availability(constant, null, constant == 1 ? length : 0);
    } else {
      final index = _integer(item['bitstream']);
      if (index >= views.length) _invalid();
      final bits = views[index];
      if (bits.length != (length + 7) ~/ 8 ||
          length % 8 != 0 && (bits.last >> (length % 8)) != 0) {
        _invalid();
      }
      var count = 0;
      for (final byte in bits) {
        var value = byte;
        while (value != 0) {
          count++;
          value &= value - 1;
        }
      }
      result = _Availability(null, bits, count);
    }
    if (item.containsKey('availableCount') &&
        _integer(item['availableCount']) != result.count) {
      _invalid();
    }
    return result;
  }
}
