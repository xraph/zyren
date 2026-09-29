import 'dart:typed_data';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'checked.dart';
import 'limits.dart';

const dracoExtension = 'KHR_draco_mesh_compression';

Future<(Map<String, Object?>, List<Uint8List>)> decodeDraco(
  Map<String, Object?> root,
  List<Uint8List> sources,
  AssetDecodeContext context,
  GltfLimits limits,
) async {
  final used = array(field(root, 'extensionsUsed', const []), 'extensionsUsed');
  final meshes = array(field(root, 'meshes', const []), 'meshes');
  final buffers = List<Uint8List>.of(sources);
  final bufferDescriptions = List<Object?>.of(
    array(field(root, 'buffers', const []), 'buffers'),
  );
  final views = List<Object?>.of(
    array(field(root, 'bufferViews', const []), 'bufferViews'),
  );
  final accessors = List<Object?>.of(
    array(field(root, 'accessors', const []), 'accessors'),
  );
  final originalAccessorCount = accessors.length,
      originalViewCount = views.length;
  var primitiveCount = 0;
  final decodedMeshes = <Object?>[];

  int appendAccessor(Map<String, Object?> description, Uint8List bytes) {
    final i = accessors.length;
    accessors.add(
      {...description, 'bufferView': views.length, 'byteOffset': 0}
        ..remove('sparse'),
    );
    views.add({'buffer': buffers.length, 'byteLength': bytes.length});
    bufferDescriptions.add({'byteLength': bytes.length});
    buffers.add(bytes);
    return i;
  }

  Map<String, Object?> accessor(Object? reference, String path) {
    final i = index(reference, originalAccessorCount, path);
    final value = object(accessors[i], 'accessors[$i]');
    integer(
      value['count'],
      'accessors[$i].count',
      min: 1,
      max: limits.maxAccessorElements,
    );
    if (value.containsKey('sparse')) {
      fail(
        'accessors[$i].sparse',
        'Sparse overrides on compressed Draco accessors are unsupported.',
        AssetLoadError.unsupportedFeature,
      );
    }
    return value;
  }

  for (var m = 0; m < meshes.length; m++) {
    final meshPath = 'meshes[$m]', mesh = object(meshes[m], 'meshes[$m]');
    final primitives = array(mesh['primitives'], '$meshPath.primitives');
    final decodedPrimitives = <Object?>[];
    for (var p = 0; p < primitives.length; p++) {
      final path = '$meshPath.primitives[$p]';
      if (++primitiveCount > limits.maxPrimitives) {
        fail(
          path,
          'Primitive count exceeds its limit.',
          AssetLoadError.limitExceeded,
        );
      }
      final primitive = object(primitives[p], path);
      final extensions = object(
        field(primitive, 'extensions', <String, Object?>{}),
        '$path.extensions',
      );
      if (!extensions.containsKey(dracoExtension)) {
        decodedPrimitives.add(primitive);
        continue;
      }
      if (!used.contains(dracoExtension)) {
        fail(
          '$path.extensions',
          'Draco compression must be declared in extensionsUsed.',
        );
      }
      final extPath = '$path.extensions.$dracoExtension';
      final extension = object(extensions[dracoExtension], extPath);
      final mode = integer(field(primitive, 'mode', 4), '$path.mode');
      if (mode != 4 && mode != 5) {
        fail(
          '$path.mode',
          'Draco primitives require triangle or triangle-strip topology.',
        );
      }
      final attributes = object(primitive['attributes'], '$path.attributes');
      final compressed = object(extension['attributes'], '$extPath.attributes');
      if (compressed.isEmpty) {
        fail('$extPath.attributes', 'Draco must map at least one attribute.');
      }
      for (final entry in compressed.entries) {
        if (!attributes.containsKey(entry.key)) {
          fail(
            '$extPath.attributes.${entry.key}',
            'Draco attribute is absent from the primitive.',
          );
        }
        integer(
          entry.value,
          '$extPath.attributes.${entry.key}',
          max: 0xffffffff,
        );
        accessor(attributes[entry.key], '$path.attributes.${entry.key}');
      }
      final indices = primitive.containsKey('indices')
          ? accessor(primitive['indices'], '$path.indices')
          : null;
      final viewIndex = index(
        extension['bufferView'],
        originalViewCount,
        '$extPath.bufferView',
      );
      final viewPath = 'bufferViews[$viewIndex]',
          view = object(views[viewIndex], 'bufferViews[$viewIndex]');
      if (view.containsKey('byteStride')) {
        fail(
          '$viewPath.byteStride',
          'Compressed Draco bytes cannot be strided.',
        );
      }
      final buffer = index(view['buffer'], sources.length, '$viewPath.buffer');
      final offset = integer(
        field(view, 'byteOffset', 0),
        '$viewPath.byteOffset',
      );
      final length = integer(
        view['byteLength'],
        '$viewPath.byteLength',
        min: 1,
      );
      if (offset > sources[buffer].length ||
          length > sources[buffer].length - offset) {
        fail(viewPath, 'Draco view exceeds its source buffer.');
      }
      final decoded = await context.decodeMesh(
        Uint8List.sublistView(sources[buffer], offset, offset + length),
        encoding: MeshEncoding.draco,
        fieldPath: extPath,
      );
      final byId = {for (final a in decoded.attributes) a.id: a};
      final mapped = Map<String, Object?>.of(attributes);
      for (final entry in compressed.entries) {
        final fieldPath = '$path.attributes.${entry.key}';
        final a = byId[entry.value];
        if (a == null) {
          fail(fieldPath, 'Decoded Draco attribute ID is missing.');
        }
        final description = accessor(attributes[entry.key], fieldPath);
        final componentType = switch (a.type) {
          MeshScalarType.int8 => 5120,
          MeshScalarType.uint8 => 5121,
          MeshScalarType.int16 => 5122,
          MeshScalarType.uint16 => 5123,
          MeshScalarType.uint32 => 5125,
          MeshScalarType.float32 => 5126,
        };
        final type = a.components == 1 ? 'SCALAR' : 'VEC${a.components}';
        if (description['count'] != decoded.vertexCount ||
            description['componentType'] != componentType ||
            description['type'] != type ||
            boolean(
                  field(description, 'normalized', false),
                  '$fieldPath.normalized',
                ) !=
                a.normalized) {
          fail(
            fieldPath,
            'Accessor count and format must match the decoded Draco attribute.',
          );
        }
        mapped[entry.key] = appendAccessor(
          entry.key == 'POSITION'
              ? _positionBounds(description, a, fieldPath)
              : description,
          a.bytes,
        );
      }
      final indexDescription =
          indices ??
          <String, Object?>{
            'componentType': 5125,
            'count': decoded.indices.length,
            'type': 'SCALAR',
          };
      final indexPath = '$path.indices';
      final count = integer(
        indexDescription['count'],
        '$indexPath.count',
        min: 1,
      );
      if (indexDescription['type'] != 'SCALAR' ||
          boolean(
            field(indexDescription, 'normalized', false),
            '$indexPath.normalized',
          ) ||
          (mode == 4 && count != decoded.indices.length) ||
          (mode == 5 &&
              indices != null &&
              count < decoded.indices.length ~/ 3 + 2)) {
        fail(
          indexPath,
          'Accessor does not match decoded Draco triangle topology.',
        );
      }
      final type = integer(
        indexDescription['componentType'],
        '$indexPath.componentType',
      );
      Uint8List indexBytes;
      if (type == 5125) {
        indexBytes = Uint8List.sublistView(decoded.indices);
      } else if (type == 5121 || type == 5123) {
        final stride = type == 5121 ? 1 : 2, max = type == 5121 ? 255 : 65535;
        if (decoded.indices.any((i) => i > max)) {
          fail(indexPath, 'Draco indices exceed accessor component storage.');
        }
        context.reserveDecodedBytes(
          decoded.indices.length * stride,
          fieldPath: indexPath,
        );
        indexBytes = Uint8List(decoded.indices.length * stride);
        final data = ByteData.sublistView(indexBytes);
        for (var i = 0; i < decoded.indices.length; i++) {
          if (stride == 1) {
            indexBytes[i] = decoded.indices[i];
          } else {
            data.setUint16(i * 2, decoded.indices[i], Endian.little);
          }
        }
      } else {
        fail(indexPath, 'Triangle indices require unsigned integer storage.');
      }
      final mappedIndices = appendAccessor({
        ...indexDescription,
        'count': decoded.indices.length,
      }, indexBytes);
      final remaining = Map<String, Object?>.of(extensions)
        ..remove(dracoExtension);
      final rewritten = {
        ...primitive,
        'attributes': mapped,
        'indices': mappedIndices,
        'mode': 4,
      };
      if (remaining.isEmpty) {
        rewritten.remove('extensions');
      } else {
        rewritten['extensions'] = remaining;
      }
      decodedPrimitives.add(rewritten);
    }
    decodedMeshes.add({...mesh, 'primitives': decodedPrimitives});
  }
  return (
    {
      ...root,
      if (meshes.isNotEmpty) 'meshes': decodedMeshes,
      if (bufferDescriptions.isNotEmpty) 'buffers': bufferDescriptions,
      if (views.isNotEmpty) 'bufferViews': views,
      if (accessors.isNotEmpty) 'accessors': accessors,
    },
    buffers,
  );
}

Map<String, Object?> _positionBounds(
  Map<String, Object?> description,
  MeshAttributeData attribute,
  String path,
) {
  if (attribute.type != MeshScalarType.float32 || attribute.components != 3) {
    return description;
  }
  final min = array(description['min'], '$path.min'),
      max = array(description['max'], '$path.max');
  if (min.length != 3 || max.length != 3) {
    fail(path, 'Positions require three-component bounds.');
  }
  final actualMin = List.filled(3, double.infinity),
      actualMax = List.filled(3, double.negativeInfinity);
  final bytes = ByteData.sublistView(attribute.bytes);
  for (var i = 0; i < attribute.bytes.length; i += 12) {
    for (var c = 0; c < 3; c++) {
      final value = bytes.getFloat32(i + c * 4, Endian.little);
      if (!value.isFinite) fail(path, 'Decoded positions must be finite.');
      actualMin[c] = math.min(actualMin[c], value);
      actualMax[c] = math.max(actualMax[c], value);
    }
  }
  for (var c = 0; c < 3; c++) {
    final lower = number(min[c], '$path.min[$c]'),
        upper = number(max[c], '$path.max[$c]');
    final tolerance = math.max(1, math.max(lower.abs(), upper.abs())) * 1e-6;
    if (lower > upper ||
        actualMin[c] < lower - tolerance ||
        actualMax[c] > upper + tolerance) {
      fail(path, 'Decoded Draco positions exceed the declared bounds.');
    }
  }
  // Draco exporters may include quantization padding in their bounds. The
  // ordinary accessor worker receives exact bounds for the reconstructed data.
  return {...description, 'min': actualMin, 'max': actualMax};
}
