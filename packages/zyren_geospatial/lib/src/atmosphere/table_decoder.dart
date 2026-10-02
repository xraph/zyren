import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

enum AtmosphereLutFormat { binary, exr }

/// Immutable RGBA16-float samples in little-endian order, with depth slices last.
final class AtmosphereTable {
  final int width, height, depth;
  final Uint8List bytes;
  AtmosphereTable._(this.width, this.height, this.depth, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();
  double value(int x, int y, int z, int channel) {
    if (x < 0 ||
        x >= width ||
        y < 0 ||
        y >= height ||
        z < 0 ||
        z >= depth ||
        channel < 0 ||
        channel > 3) {
      throw RangeError(
        'Atmosphere table coordinate is outside its dimensions.',
      );
    }
    final at = ((z * height + y) * width + x) * 8 + channel * 2;
    final word = bytes[at] | bytes[at + 1] << 8;
    final exponent = (word >> 10) & 31, mantissa = word & 1023;
    final value = exponent == 0
        ? mantissa * math.pow(2, -24)
        : (1 + mantissa / 1024) * math.pow(2, exponent - 15);
    return (word & 0x8000 == 0 ? value : -value).toDouble();
  }
}

/// CPU decoder for raw half RGBA and the source's single-part scanline EXRs.
/// EXR supports RGBA HALF, no subsampling, and NONE/ZIPS/ZIP compression.
final class AtmosphereTableDecoder {
  final int maxEncodedBytes, maxDecodedBytes;
  AtmosphereTableDecoder({
    this.maxEncodedBytes = 16 * 1024 * 1024,
    this.maxDecodedBytes = 32 * 1024 * 1024,
  }) {
    if (maxEncodedBytes < 1 ||
        maxEncodedBytes > 64 * 1024 * 1024 ||
        maxDecodedBytes < 1 ||
        maxDecodedBytes > 64 * 1024 * 1024) {
      throw ArgumentError(
        'Atmosphere table byte limits must be within 64 MiB.',
      );
    }
  }
  AtmosphereTable decode(
    Uint8List bytes, {
    required AtmosphereLutFormat format,
    required int width,
    required int height,
    int depth = 1,
    LoadCancellation? cancellation,
  }) {
    cancellation?.throwIfCancelled();
    if (width < 1 ||
        width > 4096 ||
        height < 1 ||
        height > 4096 ||
        depth < 1 ||
        depth > 256) {
      throw ArgumentError('Invalid atmosphere table dimensions.');
    }
    final count = width * height * depth * 8;
    if (bytes.length > maxEncodedBytes || count > maxDecodedBytes) _limit();
    final Uint8List result;
    if (format == AtmosphereLutFormat.binary) {
      if (bytes.length != count) _invalid();
      result = Uint8List.fromList(bytes);
    } else {
      result = _exr(bytes, width, height * depth, cancellation);
    }
    for (var at = 0; at < result.length; at += 2) {
      if (at % 16384 == 0) cancellation?.throwIfCancelled();
      if (result[at + 1] & 0x7c == 0x7c) _invalid();
    }
    return AtmosphereTable._(width, height, depth, result);
  }
}

Uint8List _exr(
  Uint8List bytes,
  int width,
  int height,
  LoadCancellation? cancellation,
) {
  final reader = _Reader(bytes);
  if (reader.u32() != 20000630) _invalid();
  if (reader.u32() != 2) _unsupported();
  final attributes = <String, (String, Uint8List)>{};
  while (true) {
    final name = reader.string();
    if (name.isEmpty) break;
    if (attributes.length >= 64 || reader.at > 65536) _limit();
    if (attributes.containsKey(name)) _invalid();
    final type = reader.string(), length = reader.u32();
    if (type.isEmpty) _invalid();
    if (length > 65536 || reader.at + length > 65536) _limit();
    attributes[name] = (type, reader.take(length));
  }
  Uint8List attribute(String name, String type, [int? length]) {
    final value = attributes[name];
    if (value == null ||
        value.$1 != type ||
        length != null && value.$2.length != length) {
      _invalid();
    }
    return value.$2;
  }

  final dataWindow = _Reader(attribute('dataWindow', 'box2i', 16));
  if (dataWindow.i32() != 0 ||
      dataWindow.i32() != 0 ||
      dataWindow.i32() != width - 1 ||
      dataWindow.i32() != height - 1) {
    _invalid();
  }
  attribute('displayWindow', 'box2i', 16);
  attribute('pixelAspectRatio', 'float', 4);
  attribute('screenWindowCenter', 'v2f', 8);
  attribute('screenWindowWidth', 'float', 4);
  if (attribute('lineOrder', 'lineOrder', 1).single != 0) _unsupported();
  final compression = attribute('compression', 'compression', 1).single;
  if (![0, 2, 3].contains(compression)) _unsupported();
  final channelReader = _Reader(attribute('channels', 'chlist'));
  final channels = <int>[];
  while (true) {
    final name = channelReader.string();
    if (name.isEmpty) break;
    final index = ['R', 'G', 'B', 'A'].indexOf(name);
    if (index < 0 || channels.length >= 4) _unsupported();
    if (channels.contains(index)) _invalid();
    if (channelReader.u32() != 1) _unsupported();
    final linear = channelReader.u8();
    if (linear > 1 || channelReader.take(3).any((n) => n != 0)) _invalid();
    if (channelReader.u32() != 1 || channelReader.u32() != 1) _unsupported();
    channels.add(index);
  }
  if (channels.length != 4 || channelReader.remaining != 0) _invalid();
  final rows = compression == 3 ? 16 : 1,
      count = (height + (compression == 3 ? 15 : 0)) ~/ rows;
  final tableEnd = reader.at + count * 8;
  reader.require(count * 8);
  final offsets = [for (var i = 0; i < count; i++) reader.u64()];
  final chunks = <(int, int, int, int)>[];
  final lines = <int>{};
  for (final offset in offsets) {
    cancellation?.throwIfCancelled();
    if (offset < tableEnd || offset > bytes.length - 8) _invalid();
    final chunk = _Reader(Uint8List.sublistView(bytes, offset));
    final y = chunk.i32(), length = chunk.u32();
    if (y < 0 || y >= height || y % rows != 0 || !lines.add(y) || length == 0) {
      _invalid();
    }
    chunk.require(length);
    chunks.add((offset, offset + 8 + length, y, length));
  }
  chunks.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < chunks.length; i++) {
    if (chunks[i].$1 < chunks[i - 1].$2) _invalid();
  }
  final output = Uint8List(width * height * 8);
  for (final (offset, end, y, length) in chunks) {
    cancellation?.throwIfCancelled();
    final rowCount = math.min(rows, height - y),
        expected = rowCount * width * 8;
    if (length > expected) _invalid();
    var data = Uint8List.sublistView(bytes, offset + 8, end);
    if (length != expected) {
      if (compression == 0) _invalid();
      data = _inflate(data, expected);
      for (var i = 1; i < data.length; i++) {
        data[i] = (data[i - 1] + data[i] - 128) & 255;
      }
      final interleaved = Uint8List(expected), middle = (expected + 1) ~/ 2;
      for (var i = 0; i < expected; i++) {
        interleaved[i] = data[i.isEven ? i ~/ 2 : middle + i ~/ 2];
      }
      data = interleaved;
    }
    for (var row = 0; row < rowCount; row++) {
      for (var channel = 0; channel < 4; channel++) {
        for (var x = 0; x < width; x++) {
          final from = ((row * 4 + channel) * width + x) * 2;
          // three.js EXRLoader reverses the flattened image before volume reshape.
          final to =
              ((height - 1 - y - row) * width + x) * 8 + channels[channel] * 2;
          output[to] = data[from];
          output[to + 1] = data[from + 1];
        }
      }
    }
  }
  return output;
}

Uint8List _inflate(Uint8List encoded, int expected) {
  final target = _InflateSink(expected);
  try {
    final sink = ZLibDecoder().startChunkedConversion(target);
    for (var i = 0; i < encoded.length; i += 4096) {
      sink.add(
        Uint8List.sublistView(encoded, i, math.min(i + 4096, encoded.length)),
      );
    }
    sink.close();
  } on FormatException {
    _invalid();
  }
  if (target.at != expected) _invalid();
  return target.bytes;
}

final class _InflateSink implements Sink<List<int>> {
  final Uint8List bytes;
  int at = 0;
  _InflateSink(int size) : bytes = Uint8List(size);
  @override
  void add(List<int> value) {
    if (value.length > bytes.length - at) _limit();
    bytes.setRange(at, at + value.length, value);
    at += value.length;
  }

  @override
  void close() {}
}

final class _Reader {
  final Uint8List bytes;
  final ByteData data;
  int at = 0;
  _Reader(this.bytes) : data = ByteData.sublistView(bytes);
  int get remaining => bytes.length - at;
  void require(int count) {
    if (count < 0 || count > remaining) _invalid();
  }

  Uint8List take(int count) {
    require(count);
    final begin = at;
    at += count;
    return Uint8List.sublistView(bytes, begin, at);
  }

  int u8() {
    require(1);
    return bytes[at++];
  }

  int u32() {
    require(4);
    final value = data.getUint32(at, Endian.little);
    at += 4;
    return value;
  }

  int i32() {
    require(4);
    final value = data.getInt32(at, Endian.little);
    at += 4;
    return value;
  }

  int u64() {
    require(8);
    final value = data.getUint64(at, Endian.little);
    at += 8;
    return value;
  }

  String string() {
    final begin = at;
    while (u8() != 0) {
      if (at - begin > 31) _unsupported();
    }
    final codes = Uint8List.sublistView(bytes, begin, at - 1);
    if (codes.any((b) => b < 32 || b > 126)) _invalid();
    return ascii.decode(codes);
  }
}

Never _invalid() => throw AssetLoadException(
  AssetLoadError.invalidData,
  'Invalid atmosphere table data.',
);
Never _limit() => throw AssetLoadException(
  AssetLoadError.limitExceeded,
  'Atmosphere table exceeds its limits.',
);
Never _unsupported() => throw AssetLoadException(
  AssetLoadError.unsupportedFeature,
  'Unsupported atmosphere table profile.',
);
