import 'dart:typed_data';

enum MlDtype {
  float32(1, 4),
  int64(7, 8),
  bool(9, 1);

  const MlDtype(this.nativeCode, this.elementBytes);
  final int nativeCode;
  final int elementBytes;
}

const mlMaxTensorBytes = 64 * 1024 * 1024;

/// Validates each multiplication before it can overflow a native integer.
int mlTensorByteLength(MlDtype dtype, List<int> shape) {
  if (shape.length > 8) throw ArgumentError('Tensor rank must be at most 8.');
  var bytes = dtype.elementBytes;
  for (final dimension in shape) {
    if (dimension <= 0 || dimension > mlMaxTensorBytes ~/ bytes) {
      throw ArgumentError('Tensor shape exceeds the 64 MiB byte budget.');
    }
    bytes *= dimension;
  }
  return bytes;
}

/// Immutable, owned little-endian tensor storage.
final class MlTensor {
  MlTensor(this.dtype, List<int> shape, Uint8List bytes)
    : shape = List.unmodifiable(shape),
      _bytes = Uint8List.fromList(bytes) {
    if (mlTensorByteLength(dtype, shape) != bytes.length) {
      throw ArgumentError('Tensor byte length differs from dtype and shape.');
    }
    if (dtype == MlDtype.bool && bytes.any((b) => b != 0 && b != 1)) {
      throw ArgumentError('Boolean storage must contain only 0 and 1.');
    }
  }

  factory MlTensor.float32(List<int> shape, Iterable<num> values) {
    final bytes = Uint8List(mlTensorByteLength(MlDtype.float32, shape));
    final data = ByteData.sublistView(bytes);
    var i = 0;
    for (final value in values) {
      if (i >= bytes.length ~/ 4) throw ArgumentError('Too many values.');
      data.setFloat32(i++ * 4, value.toDouble(), Endian.little);
    }
    if (i != bytes.length ~/ 4) throw ArgumentError('Missing values.');
    return MlTensor(MlDtype.float32, shape, bytes);
  }

  factory MlTensor.int64(List<int> shape, Iterable<int> values) {
    final bytes = Uint8List(mlTensorByteLength(MlDtype.int64, shape));
    final data = ByteData.sublistView(bytes);
    var i = 0;
    for (final value in values) {
      if (i >= bytes.length ~/ 8) throw ArgumentError('Too many values.');
      data.setInt64(i++ * 8, value, Endian.little);
    }
    if (i != bytes.length ~/ 8) throw ArgumentError('Missing values.');
    return MlTensor(MlDtype.int64, shape, bytes);
  }

  final MlDtype dtype;
  final List<int> shape;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  int get byteLength => _bytes.length;

  List<double> get float32Values {
    if (dtype != MlDtype.float32) throw StateError('Tensor is not float32.');
    final data = ByteData.sublistView(_bytes);
    return List.unmodifiable(
      List.generate(
        _bytes.length ~/ 4,
        (i) => data.getFloat32(i * 4, Endian.little),
      ),
    );
  }

  List<int> get int64Values {
    if (dtype != MlDtype.int64) throw StateError('Tensor is not int64.');
    final data = ByteData.sublistView(_bytes);
    return List.unmodifiable(
      List.generate(
        _bytes.length ~/ 8,
        (i) => data.getInt64(i * 8, Endian.little),
      ),
    );
  }

  List<bool> get boolValues {
    if (dtype != MlDtype.bool) throw StateError('Tensor is not bool.');
    return List.unmodifiable(_bytes.map((b) => b == 1));
  }

  bool get isFinite =>
      dtype != MlDtype.float32 ||
      float32Values.every((value) => value.isFinite);
}

typedef MlTensorMap = Map<String, MlTensor>;
