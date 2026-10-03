part of '../../training.dart';

const trainingMaxHeader = 65536;
const trainingMaxMessage = 16 * 1024 * 1024;
const _tensorSizes = {'f32': 4, 'f64': 8, 'i32': 4, 'u8': 1};

int _boundedInt(Object? value, int max, {int min = 0}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid wire integer.');
  }
  return value;
}

String _wireId(Object? value) {
  if (value is! String || value.isEmpty || utf8.encode(value).length > 256) {
    throw const FormatException('Invalid wire identity.');
  }
  return value;
}

Map<String, Object?> _wireMap(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Invalid wire object.');
  }
  return value;
}

int _validateFrame(Map<String, Object?> header, int maxMessage) {
  if (header['version'] != 1 ||
      !const {
        'hello',
        'reset',
        'step',
        'snapshot',
        'restore',
        'close',
      }.contains(header['operation'])) {
    throw const FormatException('Unsupported wire version or operation.');
  }
  _boundedInt(header['sequence'], 9007199254740991);
  _boundedInt(header['tick'], 9007199254740991);
  for (final key in ['run_id', 'environment_id', 'episode_id']) {
    _wireId(header[key]);
  }
  final actors = header['actor_ids'];
  if (actors is! List || actors.length > 256) {
    throw const FormatException('Invalid actors.');
  }
  final actorIds = actors.map(_wireId).toSet();
  if (actorIds.length != actors.length) {
    throw const FormatException('Duplicate actor.');
  }
  final generations = _wireMap(header['actor_generations']);
  if (generations.length != actorIds.length ||
      !actorIds.containsAll(generations.keys)) {
    throw const FormatException('Actor generation identity differs.');
  }
  for (final generation in generations.values) {
    _boundedInt(generation, 9007199254740991, min: 1);
  }

  final bytes = _boundedInt(header['payload_bytes'], maxMessage);
  final tensors = header['tensors'];
  if (tensors is! List || tensors.length > 256) {
    throw const FormatException('Invalid tensors.');
  }
  final names = <String>{}, ranges = <(int, int)>[];
  var claimed = 0;
  for (final raw in tensors) {
    final tensor = _wireMap(raw);
    final name = _wireId(tensor['name']);
    final size = _tensorSizes[tensor['dtype']];
    final shape = tensor['shape'];
    if (!names.add(name) ||
        size == null ||
        shape is! List ||
        shape.isEmpty ||
        shape.length > 8) {
      throw const FormatException('Invalid tensor descriptor.');
    }
    var count = 1;
    for (final dim in shape) {
      count *= _boundedInt(dim, maxMessage, min: 1);
      if (count > maxMessage) {
        throw const FormatException('Tensor shape exceeds limit.');
      }
    }
    final offset = _boundedInt(tensor['offset'], maxMessage),
        length = _boundedInt(tensor['length'], maxMessage);
    if (length != count * size ||
        offset + length > bytes ||
        ranges.any((r) => offset < r.$2 && r.$1 < offset + length)) {
      throw const FormatException('Tensor layout differs from shape.');
    }
    ranges.add((offset, offset + length));
    claimed += length;
  }
  if (claimed != bytes) {
    throw const FormatException('Unclaimed tensor payload.');
  }
  return bytes;
}

void _metadataBounds(Object? value) {
  final pending = <(Object?, int)>[(value, 0)];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final (current, depth) = pending.removeLast();
    if (depth > 64 || ++nodes > 8192) {
      throw const FormatException('Metadata depth or node budget exceeded.');
    }
    if (current is Map) {
      if (current.length > 8192) {
        throw const FormatException('Metadata map exceeds budget.');
      }
      for (final entry in current.entries) {
        if (entry.key is! String) {
          throw const FormatException('Metadata keys must be strings.');
        }
        pending.add((entry.key, depth + 1));
        pending.add((entry.value, depth + 1));
      }
    } else if (current is List) {
      if (current.length > 8192) {
        throw const FormatException('Metadata list exceeds budget.');
      }
      for (final child in current) {
        pending.add((child, depth + 1));
      }
    } else if (current is String) {
      if (current.length > trainingMaxHeader ||
          utf8.encode(current).length > trainingMaxHeader) {
        throw const FormatException('Metadata string exceeds budget.');
      }
    } else if (current is num) {
      if (!current.isFinite) {
        throw const FormatException('Metadata number is non-finite.');
      }
    } else if (current != null && current is! bool) {
      throw const FormatException('Unsupported metadata value.');
    }
  }
}

Map<String, Object?> _decodeMetadata(List<int> bytes) {
  var depth = 0;
  var quoted = false, escaped = false;
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
    } else if (byte == 91 || byte == 123) {
      if (++depth > 64) {
        throw const FormatException('Metadata nesting exceeds budget.');
      }
    } else if (byte == 93 || byte == 125) {
      depth--;
    }
  }
  final value = _wireMap(jsonDecode(utf8.decode(bytes)));
  _metadataBounds(value);
  return value;
}

Object? _freezeWire(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freezeWire(v))),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeWire));
  }
  return value;
}

final class TrainingFrame {
  final Map<String, Object?> header;
  final Uint8List payload;
  TrainingFrame._(this.header, this.payload);
  factory TrainingFrame(Map<String, Object?> header, Uint8List payload) {
    if (payload.length > trainingMaxMessage) {
      throw const FormatException('Payload exceeds budget.');
    }
    _metadataBounds(header);
    if (utf8.encode(jsonEncode(header)).length > trainingMaxHeader) {
      throw const FormatException('Metadata bytes exceed budget.');
    }
    if (_validateFrame(header, trainingMaxMessage) != payload.length) {
      throw const FormatException('Payload length differs.');
    }
    return TrainingFrame._(
      _freezeWire(header) as Map<String, Object?>,
      Uint8List.fromList(payload).asUnmodifiableView(),
    );
  }
  factory TrainingFrame.float32(
    Map<String, Object?> header,
    Map<String, Float32List> arrays,
  ) {
    final blocks = BytesBuilder(copy: false),
        descriptors = <Map<String, Object?>>[];
    var offset = 0;
    for (final entry in arrays.entries) {
      if (offset + entry.value.length * 4 > trainingMaxMessage) {
        throw const FormatException('Payload exceeds limit.');
      }
      final bytes = ByteData(entry.value.length * 4);
      for (var i = 0; i < entry.value.length; i++) {
        bytes.setFloat32(i * 4, entry.value[i], Endian.little);
      }
      descriptors.add({
        'name': entry.key,
        'dtype': 'f32',
        'shape': [entry.value.length],
        'offset': offset,
        'length': bytes.lengthInBytes,
      });
      offset += bytes.lengthInBytes;
      if (offset > trainingMaxMessage) {
        throw const FormatException('Payload exceeds limit.');
      }
      blocks.add(bytes.buffer.asUint8List());
    }
    return TrainingFrame({
      ...header,
      'payload_bytes': offset,
      'tensors': descriptors,
    }, blocks.takeBytes());
  }
  factory TrainingFrame.byteBlock(
    Map<String, Object?> header,
    String name,
    Uint8List bytes,
  ) {
    return TrainingFrame({
      ...header,
      'payload_bytes': bytes.length,
      'tensors': [
        {
          'name': name,
          'dtype': 'u8',
          'shape': [bytes.length],
          'offset': 0,
          'length': bytes.length,
        },
      ],
    }, bytes);
  }
  Uint8List bytes(String name) {
    for (final raw in header['tensors'] as List) {
      final tensor = _wireMap(raw);
      if (tensor['name'] == name && tensor['dtype'] == 'u8') {
        final offset = tensor['offset'] as int;
        return payload.sublist(offset, offset + (tensor['length'] as int));
      }
    }
    throw const FormatException('Byte block is missing.');
  }

  Float32List float32(String name, {List<int>? shape}) {
    for (final raw in header['tensors'] as List) {
      final tensor = _wireMap(raw);
      if (tensor['name'] != name) continue;
      final declaredShape = tensor['shape'] as List;
      if (shape != null &&
          (declaredShape.length != shape.length ||
              [
                for (var i = 0; i < shape.length; i++)
                  declaredShape[i] == shape[i],
              ].contains(false))) {
        throw const FormatException('Tensor shape differs from action schema.');
      }
      if (tensor['dtype'] != 'f32') {
        throw const FormatException('Expected f32 tensor.');
      }
      final count = (tensor['length'] as int) ~/ 4,
          offset = tensor['offset'] as int;
      final view = ByteData.sublistView(payload);
      return Float32List.fromList([
        for (var i = 0; i < count; i++)
          view.getFloat32(offset + i * 4, Endian.little),
      ]);
    }
    throw const FormatException('Tensor is missing.');
  }

  Uint8List encode({
    int maxHeader = trainingMaxHeader,
    int maxMessage = trainingMaxMessage,
  }) {
    final bytes = utf8.encode(jsonEncode(header));
    final size = _validateFrame(header, maxMessage);
    if (bytes.isEmpty ||
        bytes.length > maxHeader ||
        4 + bytes.length + size > maxMessage) {
      throw const FormatException('Message exceeds negotiated bounds.');
    }
    final prefix = ByteData(4)..setUint32(0, bytes.length, Endian.little);
    return Uint8List.fromList([
      ...prefix.buffer.asUint8List(),
      ...bytes,
      ...payload,
    ]);
  }
}

final class TrainingFrameDecoder {
  int maxHeader, maxMessage;
  Uint8List _buffer = Uint8List(0);
  Map<String, Object?>? _header;
  int? _headerLength, _payloadLength;
  TrainingFrameDecoder({
    this.maxHeader = trainingMaxHeader,
    this.maxMessage = trainingMaxMessage,
  });
  List<TrainingFrame> add(List<int> chunk) {
    _boundedInt(maxHeader, trainingMaxHeader, min: 1);
    _boundedInt(maxMessage, trainingMaxMessage, min: maxHeader + 4);
    if (chunk.length > maxMessage ||
        _buffer.length + chunk.length > maxMessage * 2) {
      throw const FormatException('Stream chunk exceeds limit.');
    }
    _buffer = Uint8List.fromList([..._buffer, ...chunk]);
    final output = <TrainingFrame>[];
    while (true) {
      if (_headerLength == null) {
        if (_buffer.length < 4) break;
        final length = ByteData.sublistView(
          _buffer,
        ).getUint32(0, Endian.little);
        _boundedInt(length, maxHeader, min: 1);
        if (4 + length > maxMessage) {
          throw const FormatException('Header exceeds message limit.');
        }
        _headerLength = length;
      }
      final start = 4 + _headerLength!;
      if (_header == null) {
        if (_buffer.length < start) break;
        _header = _decodeMetadata(_buffer.sublist(4, start));
        _payloadLength = _validateFrame(_header!, maxMessage);
        if (start + _payloadLength! > maxMessage) {
          throw const FormatException('Message exceeds limit.');
        }
      }
      final end = start + _payloadLength!;
      if (_buffer.length < end) break;
      if (output.length >= 256) {
        throw const FormatException('Frame burst exceeds budget.');
      }
      output.add(TrainingFrame(_header!, _buffer.sublist(start, end)));
      _buffer = Uint8List.fromList(_buffer.sublist(end));
      _header = null;
      _headerLength = null;
      _payloadLength = null;
    }
    return output;
  }

  void finish() {
    if (_buffer.isNotEmpty) throw const FormatException('Truncated frame.');
  }
}
