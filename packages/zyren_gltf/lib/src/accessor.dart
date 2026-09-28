import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'limits.dart';

enum AccessorUsage { generic, vertex, indices, image }

final class DecodedAccessor {
  final TypedData data;
  final int componentType, count, components;
  final String type;
  final bool normalized;
  DecodedAccessor(
    this.data,
    this.componentType,
    this.count,
    this.components,
    this.type,
    this.normalized,
  );
  List<num> get values => data as List<num>;
}

final class _View {
  final int buffer, offset, length;
  final int? stride, target;
  const _View(this.buffer, this.offset, this.length, this.stride, this.target);
}

class AccessorReader {
  final Map<String, Object?> root;
  final List<Uint8List> buffers;
  final DecodeBudget budget;
  final GltfLimits limits;
  final _views = <_View>[];
  final _usage = <int, AccessorUsage>{};
  final _cache = <int, DecodedAccessor>{};
  final _vertexAccessors = <int, Set<int>>{};
  late final List<Object?> _accessors;
  AccessorReader(
    this.root,
    this.buffers, {
    required this.budget,
    this.limits = const GltfLimits(),
  }) {
    limits.validate();
    final declared = array(field(root, 'buffers', const []), 'buffers');
    if (buffers.length != declared.length) {
      fail('buffers', 'Resolved buffer count does not match.');
    }
    final lengths = <int>[];
    for (var i = 0; i < buffers.length; i++) {
      final length = integer(
        object(declared[i], 'buffers[$i]')['byteLength'],
        'buffers[$i].byteLength',
        min: 1,
      );
      if (buffers[i].length < length) {
        fail('buffers[$i].byteLength', 'Buffer source is truncated.');
      }
      lengths.add(length);
    }
    final views = array(field(root, 'bufferViews', const []), 'bufferViews');
    for (var i = 0; i < views.length; i++) {
      final path = 'bufferViews[$i]',
          view = object(views[i], 'bufferViews[$i]');
      final buffer = index(view['buffer'], buffers.length, '$path.buffer');
      final offset = integer(field(view, 'byteOffset', 0), '$path.byteOffset');
      final length = integer(view['byteLength'], '$path.byteLength', min: 1);
      if (offset > lengths[buffer] || length > lengths[buffer] - offset) {
        fail(path, 'Buffer view exceeds its declared buffer.');
      }
      final stride = view.containsKey('byteStride')
          ? integer(view['byteStride'], '$path.byteStride', min: 4, max: 252)
          : null;
      if (stride != null && stride % 4 != 0) {
        fail('$path.byteStride', 'Vertex stride must be a multiple of four.');
      }
      final target = view.containsKey('target')
          ? integer(view['target'], '$path.target')
          : null;
      if (target != null && target != 34962 && target != 34963) {
        fail('$path.target', 'Unknown buffer view target.');
      }
      if (target == 34963 && stride != null) {
        fail('$path.byteStride', 'Index views cannot be strided.');
      }
      _views.add(_View(buffer, offset, length, stride, target));
    }
    _accessors = array(field(root, 'accessors', const []), 'accessors');
    if (_accessors.length + _views.length + buffers.length >
        limits.maxObjects) {
      fail(
        'accessors',
        'Binary object count exceeds its limit.',
        AssetLoadError.limitExceeded,
      );
    }
  }

  Uint8List imageBytes(Object? reference, String path) {
    final i = index(reference, _views.length, path),
        view = _views[index(reference, _views.length, path)];
    _use(i, AccessorUsage.image, path);
    if (view.target != null || view.stride != null) {
      fail(path, 'Image views cannot carry a target or stride.');
    }
    return Uint8List.sublistView(
      buffers[view.buffer],
      view.offset,
      view.offset + view.length,
    ).asUnmodifiableView();
  }

  void _use(int viewIndex, AccessorUsage usage, String path) {
    if (usage == AccessorUsage.generic) return;
    final previous = _usage[viewIndex];
    if (previous != null && previous != usage) {
      fail(path, 'A buffer view mixes incompatible data uses.');
    }
    _usage[viewIndex] = usage;
  }

  DecodedAccessor read(
    int accessorIndex, {
    AccessorUsage usage = AccessorUsage.generic,
  }) {
    final path = 'accessors[$accessorIndex]';
    index(accessorIndex, _accessors.length, path);
    final accessor = object(_accessors[accessorIndex], path);
    final componentType = integer(
      accessor['componentType'],
      '$path.componentType',
    );
    final bytesPerComponent = switch (componentType) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      5125 || 5126 => 4,
      _ => 0,
    };
    if (bytesPerComponent == 0) {
      fail('$path.componentType', 'Unknown accessor component type.');
    }
    final type = string(accessor['type'], '$path.type');
    final (rows, columns) = switch (type) {
      'SCALAR' => (1, 1),
      'VEC2' => (2, 1),
      'VEC3' => (3, 1),
      'VEC4' => (4, 1),
      'MAT2' => (2, 2),
      'MAT3' => (3, 3),
      'MAT4' => (4, 4),
      _ => (0, 0),
    };
    if (rows == 0) fail('$path.type', 'Unknown accessor shape.');
    final components = rows * columns;
    final count = integer(accessor['count'], '$path.count', min: 1);
    if (count > limits.maxAccessorElements) {
      fail(
        '$path.count',
        'Accessor count exceeds its limit.',
        AssetLoadError.limitExceeded,
      );
    }
    final normalized = boolean(
      field(accessor, 'normalized', false),
      '$path.normalized',
    );
    if (normalized && (componentType == 5125 || componentType == 5126)) {
      fail(
        '$path.normalized',
        'Only 8-bit and 16-bit integer accessors can be normalized.',
      );
    }
    final columnStride = columns == 1
        ? rows * bytesPerComponent
        : (rows * bytesPerComponent + 3) & ~3;
    final elementStride = columnStride * columns;
    final span = (columns - 1) * columnStride + rows * bytesPerComponent;
    final offset = integer(
      field(accessor, 'byteOffset', 0),
      '$path.byteOffset',
    );
    final viewIndex = accessor.containsKey('bufferView')
        ? index(accessor['bufferView'], _views.length, '$path.bufferView')
        : null;
    _View? view;
    if (viewIndex != null) {
      view = _views[viewIndex];
      _use(viewIndex, usage, path);
      _range(
        view,
        offset,
        count,
        view.stride ?? elementStride,
        span,
        bytesPerComponent,
        columns > 1,
        path,
      );
      if (usage == AccessorUsage.vertex &&
          (offset % 4 != 0 ||
              (count > 1 && (view.stride ?? elementStride) % 4 != 0) ||
              view.target == 34963)) {
        fail(
          path,
          'Vertex attributes need four-byte element alignment and an attribute view.',
        );
      }
      if (usage == AccessorUsage.vertex) {
        final sharing = _vertexAccessors[viewIndex] ??= <int>{};
        sharing.add(accessorIndex);
        if (sharing.length > 1 && view.stride == null) {
          fail(
            path,
            'Shared vertex attribute views must define a byte stride.',
          );
        }
      }
      if (usage == AccessorUsage.indices &&
          (view.stride != null || view.target == 34962)) {
        fail(path, 'Indices need a tightly packed index view.');
      }
    } else if (offset != 0) {
      fail(
        '$path.byteOffset',
        'An accessor without a buffer view cannot have an offset.',
      );
    }
    if (usage == AccessorUsage.indices &&
        (type != 'SCALAR' ||
            normalized ||
            !{5121, 5123, 5125}.contains(componentType))) {
      fail(path, 'Indices need unsigned, non-normalized scalar values.');
    }
    _bounds(accessor, components, componentType, path);
    final cached = _cache[accessorIndex];
    if (cached != null) {
      if (usage == AccessorUsage.indices) _validateIndices(cached, path);
      return cached;
    }
    budget.reserve(
      count * components * (normalized ? 4 : bytesPerComponent),
      path,
    );
    final length = count * components;
    final TypedData output = normalized
        ? Float32List(length)
        : switch (componentType) {
            5120 => Int8List(length),
            5121 => Uint8List(length),
            5122 => Int16List(length),
            5123 => Uint16List(length),
            5125 => Uint32List(length),
            _ => Float32List(length),
          };
    final values = output as List<num>;
    void copy(
      _View source,
      int sourceOffset,
      int stride,
      int element,
      int destination,
    ) {
      final data = ByteData.sublistView(buffers[source.buffer]);
      for (var column = 0; column < columns; column++) {
        for (var row = 0; row < rows; row++) {
          final at =
              source.offset +
              sourceOffset +
              element * stride +
              column * columnStride +
              row * bytesPerComponent;
          num value = _component(data, at, componentType);
          if (!value.isFinite) {
            fail(path, 'Accessor contains a nonfinite value.');
          }
          if (normalized) {
            value = switch (componentType) {
              5120 => math.max(value / 127, -1),
              5121 => value / 255,
              5122 => math.max(value / 32767, -1),
              _ => value / 65535,
            };
          }
          values[destination * components + column * rows + row] = normalized
              ? value.toDouble()
              : value;
        }
      }
    }

    if (view != null) {
      for (var element = 0; element < count; element++) {
        copy(view, offset, view.stride ?? elementStride, element, element);
      }
    }
    if (accessor.containsKey('sparse')) {
      final sparse = object(accessor['sparse'], '$path.sparse');
      final sparseCount = integer(
        sparse['count'],
        '$path.sparse.count',
        min: 1,
        max: count,
      );
      final indices = object(sparse['indices'], '$path.sparse.indices');
      final indexType = integer(
        indices['componentType'],
        '$path.sparse.indices.componentType',
      );
      if (!{5121, 5123, 5125}.contains(indexType)) {
        fail(
          '$path.sparse.indices.componentType',
          'Sparse indices must be unsigned.',
        );
      }
      final indexSize = indexType == 5121
          ? 1
          : indexType == 5123
          ? 2
          : 4;
      final indexView = _sparseView(
        indices['bufferView'],
        '$path.sparse.indices.bufferView',
      );
      final indexOffset = integer(
        field(indices, 'byteOffset', 0),
        '$path.sparse.indices.byteOffset',
      );
      _range(
        indexView,
        indexOffset,
        sparseCount,
        indexSize,
        indexSize,
        indexSize,
        false,
        '$path.sparse.indices',
      );
      final replacements = object(sparse['values'], '$path.sparse.values');
      final replacementView = _sparseView(
        replacements['bufferView'],
        '$path.sparse.values.bufferView',
      );
      final replacementOffset = integer(
        field(replacements, 'byteOffset', 0),
        '$path.sparse.values.byteOffset',
      );
      _range(
        replacementView,
        replacementOffset,
        sparseCount,
        elementStride,
        span,
        bytesPerComponent,
        columns > 1,
        '$path.sparse.values',
      );
      final indicesData = ByteData.sublistView(buffers[indexView.buffer]);
      var previous = -1;
      for (var i = 0; i < sparseCount; i++) {
        final destination = _component(
          indicesData,
          indexView.offset + indexOffset + i * indexSize,
          indexType,
        ).toInt();
        if (destination <= previous || destination >= count) {
          fail(
            '$path.sparse.indices',
            'Sparse indices must increase strictly and fit the accessor.',
          );
        }
        copy(replacementView, replacementOffset, elementStride, i, destination);
        previous = destination;
      }
    }
    final immutable = switch (output) {
      Float32List v => v.asUnmodifiableView(),
      Int8List v => v.asUnmodifiableView(),
      Uint8List v => v.asUnmodifiableView(),
      Int16List v => v.asUnmodifiableView(),
      Uint16List v => v.asUnmodifiableView(),
      Uint32List v => v.asUnmodifiableView(),
      _ => throw StateError('Unknown accessor storage.'),
    };
    final decoded = DecodedAccessor(
      immutable,
      componentType,
      count,
      components,
      type,
      normalized,
    );
    if (usage == AccessorUsage.indices) _validateIndices(decoded, path);
    return _cache[accessorIndex] = decoded;
  }

  _View _sparseView(Object? reference, String path) {
    final view = _views[index(reference, _views.length, path)];
    if (view.stride != null || view.target != null) {
      fail(path, 'Sparse views cannot carry a target or stride.');
    }
    return view;
  }

  void _validateIndices(DecodedAccessor accessor, String path) {
    final maximum = switch (accessor.componentType) {
      5121 => 255,
      5123 => 65535,
      _ => 0xffffffff,
    };
    if (accessor.values.contains(maximum)) {
      fail(path, 'Primitive restart index values are not valid glTF indices.');
    }
  }

  void _range(
    _View view,
    int offset,
    int count,
    int stride,
    int span,
    int componentSize,
    bool matrix,
    String path,
  ) {
    if (offset % componentSize != 0 ||
        (view.offset + offset) % componentSize != 0 ||
        stride % componentSize != 0 ||
        stride < span ||
        matrix && ((view.offset + offset) % 4 != 0 || stride % 4 != 0)) {
      fail(path, 'Accessor alignment or stride is invalid.');
    }
    if (offset > view.length ||
        span > view.length - offset ||
        (count - 1) * stride > view.length - offset - span) {
      fail(path, 'Accessor exceeds its buffer view.');
    }
  }

  void _bounds(
    Map<String, Object?> accessor,
    int components,
    int componentType,
    String path,
  ) {
    for (final key in ['min', 'max']) {
      if (!accessor.containsKey(key)) continue;
      final values = array(accessor[key], '$path.$key');
      if (values.length != components) {
        fail('$path.$key', 'Accessor bounds must match its component count.');
      }
      final (minimum, maximum) = switch (componentType) {
        5120 => (-128, 127),
        5121 => (0, 255),
        5122 => (-32768, 32767),
        5123 => (0, 65535),
        5125 => (0, 0xffffffff),
        _ => (-3.4028234663852886e38, 3.4028234663852886e38),
      };
      for (var i = 0; i < values.length; i++) {
        final value = number(values[i], '$path.$key[$i]');
        if (value < minimum ||
            value > maximum ||
            componentType != 5126 && value != value.truncateToDouble()) {
          fail(
            '$path.$key[$i]',
            'Bounds must fit the accessor component type.',
          );
        }
      }
    }
    if (accessor['min'] case List<Object?> minimum) {
      if (accessor['max'] case List<Object?> maximum) {
        for (var i = 0; i < components; i++) {
          if ((minimum[i] as num) > (maximum[i] as num)) {
            fail('$path.min', 'Accessor minimum exceeds its maximum.');
          }
        }
      }
    }
  }
}

num _component(ByteData data, int offset, int type) => switch (type) {
  5120 => data.getInt8(offset),
  5121 => data.getUint8(offset),
  5122 => data.getInt16(offset, Endian.little),
  5123 => data.getUint16(offset, Endian.little),
  5125 => data.getUint32(offset, Endian.little),
  _ => data.getFloat32(offset, Endian.little),
};
