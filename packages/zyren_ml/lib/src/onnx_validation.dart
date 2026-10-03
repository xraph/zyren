import 'dart:convert';
import 'dart:typed_data';

import 'manifest.dart';
import 'result.dart';
import 'tensor.dart';

/// Reads only ONNX envelope metadata. ORT validates graph/operator semantics.
/// Traversal covers nested graphs, constant tensors, sparse tensors and functions.
void validateOnnxEnvelope(Uint8List bytes, MlModelManifest manifest) {
  var graphCount = 0;
  var opsetCount = 0;
  for (final field in _fields(bytes)) {
    if (field.number == 7) {
      _graph(field.bytes!, 0);
      _interface(field.bytes!, manifest);
      graphCount++;
    } else if (field.number == 8) {
      _opset(field.bytes!, manifest.opset);
      opsetCount++;
    } else if (field.number == 25) {
      // Local functions can hide custom operators and additional opsets.
      for (final f in _fields(field.bytes!)) {
        if (f.number == 7) _node(f.bytes!, 0);
        if (f.number == 9) _opset(f.bytes!, manifest.opset);
        if (f.number == 10) _domain(f.bytes!);
        if (f.number == 11) _attribute(f.bytes!, 0);
      }
    }
  }
  if (graphCount != 1 || opsetCount == 0) {
    throw const FormatException('ONNX needs one graph and a declared opset.');
  }
}

void _interface(Uint8List bytes, MlModelManifest manifest) {
  final inputs = <String, MlTensorSpec>{};
  final outputs = <String, MlTensorSpec>{};
  for (final field in _fields(bytes)) {
    if (field.number != 11 && field.number != 12) continue;
    String? name;
    Uint8List? type;
    for (final value in _fields(field.bytes!)) {
      if (value.number == 1) name = utf8.decode(value.bytes!);
      if (value.number == 2) type = value.bytes;
    }
    if (name == null || type == null) {
      throw const FormatException('ONNX interface needs name and tensor type.');
    }
    int? dtype;
    List<int>? shape;
    for (final value in _fields(type)) {
      if (value.number != 1) continue;
      for (final tensor in _fields(value.bytes!)) {
        if (tensor.number == 1) dtype = tensor.integer;
        if (tensor.number == 2) {
          shape = [];
          for (final dimension in _fields(tensor.bytes!)) {
            if (dimension.number != 1) continue;
            int? size;
            for (final d in _fields(dimension.bytes!)) {
              if (d.number == 1) size = d.integer;
              if (d.number == 2 && utf8.decode(d.bytes!).isNotEmpty) size = -1;
            }
            if (size == null) {
              throw const FormatException('Unspecified ONNX dimension.');
            }
            shape.add(size);
          }
        }
      }
    }
    final declared = (field.number == 11 ? manifest.inputs : manifest.outputs)
        .where((spec) => spec.name == name)
        .firstOrNull;
    final actualDtype = MlDtype.values
        .where((d) => d.nativeCode == dtype)
        .firstOrNull;
    if (declared == null ||
        actualDtype != declared.dtype ||
        shape == null ||
        jsonEncode(shape) != jsonEncode(declared.shape)) {
      throw const FormatException(
        'Actual ONNX tensor interface differs from manifest.',
      );
    }
    final target = field.number == 11 ? inputs : outputs;
    if (target.containsKey(name)) {
      throw const FormatException('Duplicate ONNX interface tensor.');
    }
    target[name] = declared;
  }
  if (inputs.length != manifest.inputs.length ||
      outputs.length != manifest.outputs.length) {
    throw const FormatException(
      'Manifest tensor names differ from actual ONNX interface.',
    );
  }
}

void _domain(Uint8List bytes) {
  final domain = utf8.decode(bytes);
  if (domain != '' && domain != 'ai.onnx') {
    throw MlLoadException(
      MlRunStatus.unsupported,
      'Custom ONNX domain: $domain',
    );
  }
}

void _opset(Uint8List bytes, int expected) {
  int? version;
  for (final field in _fields(bytes)) {
    if (field.number == 1) _domain(field.bytes!);
    if (field.number == 2) version = field.integer;
  }
  if (version != expected) {
    throw const MlLoadException(
      MlRunStatus.unsupported,
      'Actual ONNX opset differs from the manifest pin.',
    );
  }
}

void _depth(int depth) {
  if (depth > 32) throw const FormatException('ONNX graph nesting exceeds 32.');
}

void _graph(Uint8List bytes, int depth) {
  _depth(depth);
  for (final f in _fields(bytes)) {
    if (f.number == 1) _node(f.bytes!, depth + 1);
    if (f.number == 5) _tensor(f.bytes!);
    if (f.number == 15) _sparse(f.bytes!);
  }
}

void _node(Uint8List bytes, int depth) {
  _depth(depth);
  for (final f in _fields(bytes)) {
    if (f.number == 7) _domain(f.bytes!);
    if (f.number == 5) _attribute(f.bytes!, depth + 1);
  }
}

void _attribute(Uint8List bytes, int depth) {
  _depth(depth);
  for (final f in _fields(bytes)) {
    if (f.number == 5 || f.number == 10) _tensor(f.bytes!);
    if (f.number == 6 || f.number == 11) _graph(f.bytes!, depth + 1);
    if (f.number == 22 || f.number == 23) _sparse(f.bytes!);
  }
}

void _sparse(Uint8List bytes) {
  for (final f in _fields(bytes)) {
    if (f.number == 1 || f.number == 2) _tensor(f.bytes!);
  }
}

void _tensor(Uint8List bytes) {
  var external = false;
  for (final f in _fields(bytes)) {
    if (f.number == 13) {
      external = true;
      String? key, value;
      for (final entry in _fields(f.bytes!)) {
        if (entry.number == 1) key = utf8.decode(entry.bytes!);
        if (entry.number == 2) value = utf8.decode(entry.bytes!);
      }
      if (key == 'location') validateModelAssetPath(value ?? '');
    }
    if (f.number == 14 && f.integer != 0) external = true;
  }
  if (external) {
    throw const MlLoadException(
      MlRunStatus.unsupported,
      'A1 accepts self-contained ONNX tensors only. Embed external data.',
    );
  }
}

final class _Field {
  const _Field(this.number, {this.bytes, this.integer});
  final int number;
  final Uint8List? bytes;
  final int? integer;
}

Iterable<_Field> _fields(Uint8List bytes) sync* {
  var cursor = 0;
  int varint() {
    var value = 0;
    for (var i = 0; i < 10; i++) {
      if (cursor >= bytes.length) {
        throw const FormatException('Truncated protobuf.');
      }
      final byte = bytes[cursor++];
      if (i == 9 && byte > 1) {
        throw const FormatException('Protobuf integer overflow.');
      }
      value |= (byte & 127) << (i * 7);
      if (byte < 128) return value;
    }
    throw const FormatException('Protobuf varint exceeds 64 bits.');
  }

  while (cursor < bytes.length) {
    final tag = varint();
    final number = tag >> 3;
    if (number <= 0) throw const FormatException('Invalid protobuf tag.');
    final wire = tag & 7;
    if (wire == 0) {
      yield _Field(number, integer: varint());
    } else if (wire == 2) {
      final length = varint();
      if (length < 0 || length > bytes.length - cursor) {
        throw const FormatException('Invalid protobuf field length.');
      }
      yield _Field(
        number,
        bytes: Uint8List.sublistView(bytes, cursor, cursor + length),
      );
      cursor += length;
    } else if (wire == 1 || wire == 5) {
      cursor += wire == 1 ? 8 : 4;
      if (cursor > bytes.length) {
        throw const FormatException('Truncated protobuf field.');
      }
    } else {
      throw const FormatException('Unsupported protobuf wire type.');
    }
  }
}
