import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'accessor.dart';
import 'checked.dart';
import 'instance_validation.dart';
import 'material_decoder.dart';
import 'node_decoder.dart';
import 'options.dart';
import 'recipes.dart';

PreparedModel prepareModel(
  Map<String, Object?> root,
  List<Uint8List> buffers,
  GltfOptions options,
  int maxDecodedBytes,
) {
  if (root.containsKey('animations')) {
    fail(
      'animations',
      'Animated models need the animation profile, which is not yet implemented.',
      AssetLoadError.unsupportedFeature,
    );
  }
  final budget = DecodeBudget(maxDecodedBytes);
  final reader = AccessorReader(
    root,
    buffers,
    limits: options.limits,
    budget: budget,
  );
  final rawMeshes = array(field(root, 'meshes', const []), 'meshes');
  final (nodes, scenes, selected) = decodeNodes(
    root,
    options.limits,
    rawMeshes.length,
  );
  validateInstances(
    nodes,
    scenes,
    rawMeshes,
    options.limits.maxPrimitives,
    options.limits.maxLights,
  );
  final issues = <SceneIssue>[];
  final materials = MaterialDecoder(root, reader, options, issues);
  final meshes = <List<PrimitiveRecipe>>[];
  var primitiveCount = 0;
  for (var m = 0; m < rawMeshes.length; m++) {
    final meshPath = 'meshes[$m]', mesh = object(rawMeshes[m], 'meshes[$m]');
    if (mesh.containsKey('weights')) {
      fail(
        '$meshPath.weights',
        'Morph targets are not yet supported.',
        AssetLoadError.unsupportedFeature,
      );
    }
    final name = mesh.containsKey('name')
        ? string(mesh['name'], '$meshPath.name')
        : null;
    final rawPrimitives = array(mesh['primitives'], '$meshPath.primitives');
    if (rawPrimitives.isEmpty) {
      fail('$meshPath.primitives', 'A mesh needs at least one primitive.');
    }
    final primitives = <PrimitiveRecipe>[];
    for (var p = 0; p < rawPrimitives.length; p++) {
      final path = '$meshPath.primitives[$p]',
          primitive = object(rawPrimitives[p], '$meshPath.primitives[$p]');
      if (++primitiveCount > options.limits.maxPrimitives) {
        fail(
          path,
          'Primitive count exceeds its limit.',
          AssetLoadError.limitExceeded,
        );
      }
      if (primitive.containsKey('targets')) {
        fail(
          '$path.targets',
          'Morph targets are not yet supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final attributes = object(primitive['attributes'], '$path.attributes');
      final decoded = <String, DecodedAccessor>{};
      for (final entry in attributes.entries) {
        final semantic = entry.key,
            attributePath = '$path.attributes.$semantic';
        if (semantic.startsWith('JOINTS_') || semantic.startsWith('WEIGHTS_')) {
          fail(
            attributePath,
            'This vertex semantic is not yet supported by the native model profile.',
            AssetLoadError.unsupportedFeature,
          );
        }
        if (![
              'POSITION',
              'NORMAL',
              'TANGENT',
              'COLOR_0',
              'TEXCOORD_0',
              'TEXCOORD_1',
            ].contains(semantic) &&
            !semantic.startsWith('_')) {
          fail(
            attributePath,
            'This vertex semantic is unsupported.',
            AssetLoadError.unsupportedFeature,
          );
        }
        final a = reader.read(
          index(
            entry.value,
            array(field(root, 'accessors', const []), 'accessors').length,
            attributePath,
          ),
          usage: AccessorUsage.vertex,
        );
        if (semantic == 'POSITION' || semantic == 'NORMAL') {
          if (a.type != 'VEC3' || a.componentType != 5126 || a.normalized) {
            fail(
              attributePath,
              'Position and normal attributes require float VEC3 accessors.',
            );
          }
        } else if (semantic == 'TANGENT') {
          if (a.type != 'VEC4' || a.componentType != 5126 || a.normalized) {
            fail(attributePath, 'Tangents require float VEC4 accessors.');
          }
        } else if (semantic == 'COLOR_0') {
          if (!['VEC3', 'VEC4'].contains(a.type) ||
              !((a.componentType == 5126 && !a.normalized) ||
                  ([5121, 5123].contains(a.componentType) && a.normalized))) {
            fail(
              attributePath,
              'Colors require float or normalized unsigned RGB/RGBA accessors.',
            );
          }
        } else if (semantic.startsWith('TEXCOORD_')) {
          if (a.type != 'VEC2' ||
              !((a.componentType == 5126 && !a.normalized) ||
                  ([5121, 5123].contains(a.componentType) && a.normalized))) {
            fail(
              attributePath,
              'UVs require float or normalized unsigned VEC2 accessors.',
            );
          }
        }
        decoded[semantic] = a;
        if (semantic.startsWith('_')) {
          issues.add(
            SceneIssue(
              code: 'gltf.unusedAttribute',
              message:
                  'The native material does not consume custom attribute $semantic.',
              operation: 'load',
              resourceLabel: attributePath,
              severity: IssueSeverity.info,
            ),
          );
        }
      }
      final position = decoded['POSITION'];
      if (position == null) {
        fail('$path.attributes.POSITION', 'Mesh primitives require positions.');
      }
      if (position.count > 1000000) {
        fail(
          '$path.attributes.POSITION',
          'Vertex count exceeds the native geometry limit.',
          AssetLoadError.limitExceeded,
        );
      }
      if (decoded.values.any((a) => a.count != position.count)) {
        fail('$path.attributes', 'Vertex attribute counts must match.');
      }
      _positionBounds(root, attributes['POSITION'] as num, position);
      final suppliedNormals = decoded['NORMAL'];
      if (suppliedNormals != null) {
        _unitVectors(suppliedNormals, '$path.attributes.NORMAL');
      }
      final tangent = decoded['TANGENT'];
      if (tangent != null && suppliedNormals != null) {
        _unitVectors(tangent, '$path.attributes.TANGENT');
      }
      final mode = integer(field(primitive, 'mode', 4), '$path.mode', max: 6);
      List<int> indices;
      if (primitive.containsKey('indices')) {
        final accessor = index(
          primitive['indices'],
          array(field(root, 'accessors', const []), 'accessors').length,
          '$path.indices',
        );
        indices = reader
            .read(accessor, usage: AccessorUsage.indices)
            .values
            .cast<int>();
        if (indices.any((value) => value >= position.count)) {
          fail('$path.indices', 'Index exceeds the vertex count.');
        }
      } else {
        budget.reserve(position.count * 4, path);
        indices = Uint32List(position.count);
        for (var i = 0; i < indices.length; i++) {
          indices[i] = i;
        }
      }
      indices = _expandIndices(indices, mode, budget, path);
      final topology = switch (mode) {
        0 => GeometryTopology.points,
        1 || 2 => GeometryTopology.lineSegments,
        3 => GeometryTopology.lineStrip,
        _ => GeometryTopology.triangles,
      };
      final material = materials.read(
        primitive['material'],
        '$path.material',
        present: primitive.containsKey('material'),
      );
      if (material.standard && topology != GeometryTopology.triangles) {
        fail(
          '$path.material',
          'Lit points and lines are not yet supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      for (final binding in material.maps) {
        if (topology != GeometryTopology.triangles) {
          fail(
            '$path.material',
            'Textured points and lines are not yet supported.',
            AssetLoadError.unsupportedFeature,
          );
        }
        if (!decoded.containsKey('TEXCOORD_${binding.uvSet}')) {
          fail(
            '$path.attributes.TEXCOORD_${binding.uvSet}',
            'The material requires UV set ${binding.uvSet}.',
          );
        }
      }
      final output = <VertexSemantic, VertexAttribute>{};
      final flat =
          topology == GeometryTopology.triangles && suppliedNormals == null;
      final vertexCount = flat ? indices.length : position.count;
      if (vertexCount > 1000000) {
        fail(
          path,
          'Generated flat normals exceed the native vertex limit.',
          AssetLoadError.limitExceeded,
        );
      }
      void attribute(
        VertexSemantic semantic,
        Float32List values,
        VertexFormat format,
      ) {
        budget.reserve(values.lengthInBytes, path);
        output[semantic] = VertexAttribute(values, format: format);
      }

      Float32List expanded(DecodedAccessor input) {
        final values = input.data as Float32List;
        if (!flat) return values;
        budget.reserve(vertexCount * input.components * 4, path);
        final result = Float32List(vertexCount * input.components);
        for (var i = 0; i < indices.length; i++) {
          for (var c = 0; c < input.components; c++) {
            result[i * input.components + c] =
                values[indices[i] * input.components + c];
          }
        }
        return result;
      }

      final positions = expanded(position);
      attribute(VertexSemantic.position, positions, VertexFormat.float32x3);
      if (suppliedNormals != null) {
        attribute(
          VertexSemantic.normal,
          suppliedNormals.data as Float32List,
          VertexFormat.float32x3,
        );
      } else {
        budget.reserve(vertexCount * 12, path);
        final normals = Float32List(vertexCount * 3);
        if (flat) {
          for (var i = 0; i < positions.length; i += 9) {
            Vec3 point(int at) =>
                Vec3(positions[at], positions[at + 1], positions[at + 2]);
            final a = point(i),
                b = point(i + 3),
                c = point(i + 6),
                cross = (b - a).cross(c - a);
            final n = cross.length2 == 0
                ? const Vec3(0, 0, 1)
                : cross.normalized();
            for (var at = i; at < i + 9; at += 3) {
              normals[at] = n.x;
              normals[at + 1] = n.y;
              normals[at + 2] = n.z;
            }
          }
        } else {
          for (var i = 2; i < normals.length; i += 3) {
            normals[i] = 1;
          }
        }
        attribute(VertexSemantic.normal, normals, VertexFormat.float32x3);
      }
      if (decoded['COLOR_0'] case final color?) {
        final values = expanded(color);
        budget.reserve(vertexCount * 16, path);
        final colors = Float32List(vertexCount * 4);
        for (var i = 0; i < vertexCount; i++) {
          for (var c = 0; c < 4; c++) {
            colors[i * 4 + c] = c >= color.components
                ? 1
                : values[i * color.components + c].clamp(0, 1);
          }
        }
        attribute(VertexSemantic.color, colors, VertexFormat.float32x4);
      }
      if (topology == GeometryTopology.triangles) {
        if (tangent != null && suppliedNormals != null) {
          attribute(
            VertexSemantic.tangent,
            tangent.data as Float32List,
            VertexFormat.float32x4,
          );
        }
        for (final (name, semantic) in [
          ('TEXCOORD_0', VertexSemantic.uv0),
          ('TEXCOORD_1', VertexSemantic.uv1),
        ]) {
          if (decoded[name] case final a?) {
            attribute(semantic, expanded(a), VertexFormat.float32x2);
          }
        }
      }
      if (flat) {
        budget.reserve(vertexCount * 4, path);
        indices = Uint32List(vertexCount);
        for (var i = 0; i < vertexCount; i++) {
          indices[i] = i;
        }
      }
      final format = indices.every((i) => i <= 65535)
          ? IndexFormat.uint16
          : IndexFormat.uint32;
      budget.reserve(indices.length * format.bytesPerIndex, path);
      if (topology != GeometryTopology.triangles) {
        final count = topology == GeometryTopology.lineSegments
            ? indices.length ~/ 2
            : topology == GeometryTopology.lineStrip
            ? indices.length - 1
            : indices.length;
        if (count > 250000) {
          fail(
            path,
            'Expanded primitives exceed the native limit.',
            AssetLoadError.limitExceeded,
          );
        }
      }
      primitives.add(
        PrimitiveRecipe(
          GeometryData(
            attributes: output,
            indices: indices,
            indexFormat: format,
            topology: topology,
          ),
          material,
          name,
        ),
      );
    }
    meshes.add(List.unmodifiable(primitives));
  }
  return PreparedModel(
    nodes,
    scenes,
    selected,
    List.unmodifiable(meshes),
    Map.unmodifiable(materials.images),
    List.unmodifiable(issues),
    budget.usedBytes,
  );
}

List<int> _expandIndices(
  List<int> source,
  int mode,
  DecodeBudget budget,
  String path,
) {
  final n = source.length;
  if ((mode == 1 && n % 2 != 0) ||
      (mode == 4 && n % 3 != 0) ||
      ([1, 2, 3].contains(mode) && n < 2) ||
      (mode >= 4 && n < 3)) {
    fail(path, 'Index count does not fit the primitive topology.');
  }
  if (![2, 5, 6].contains(mode)) return source;
  final count = mode == 2 ? n * 2 : (n - 2) * 3;
  if (count > 3000000) {
    fail(
      path,
      'Expanded indices exceed the native limit.',
      AssetLoadError.limitExceeded,
    );
  }
  budget.reserve(count * 4, path);
  final output = Uint32List(count);
  if (mode == 2) {
    for (var i = 0; i < n; i++) {
      output[2 * i] = source[i];
      output[2 * i + 1] = source[(i + 1) % n];
    }
  } else {
    for (var i = 0; i < n - 2; i++) {
      output[3 * i] = mode == 6 ? source[0] : source[i + (i.isOdd ? 1 : 0)];
      output[3 * i + 1] = mode == 6
          ? source[i + 1]
          : source[i + (i.isOdd ? 0 : 1)];
      output[3 * i + 2] = source[i + 2];
    }
  }
  return output;
}

void _unitVectors(DecodedAccessor accessor, String path) {
  final v = accessor.values;
  for (var i = 0; i < v.length; i += accessor.components) {
    final length2 = v[i] * v[i] + v[i + 1] * v[i + 1] + v[i + 2] * v[i + 2];
    if ((length2 - 1).abs() > 1e-3 ||
        (accessor.components == 4 && v[i + 3].abs() != 1)) {
      fail(
        path,
        'Normals and tangent directions must be unit vectors with valid handedness.',
      );
    }
  }
}

void _positionBounds(
  Map<String, Object?> root,
  num reference,
  DecodedAccessor position,
) {
  final i = reference.toInt(), path = 'accessors[${reference.toInt()}]';
  final accessor = object((root['accessors'] as List)[i], path);
  final min = numbers(accessor['min'], 3, '$path.min'),
      max = numbers(accessor['max'], 3, '$path.max');
  final actualMin = List.filled(3, double.infinity),
      actualMax = List.filled(3, double.negativeInfinity);
  final values = position.values;
  for (var at = 0; at < values.length; at += 3) {
    for (var c = 0; c < 3; c++) {
      actualMin[c] = math.min(actualMin[c], values[at + c].toDouble());
      actualMax[c] = math.max(actualMax[c], values[at + c].toDouble());
    }
  }
  final expectedMin = Float32List.fromList(min),
      expectedMax = Float32List.fromList(max);
  for (var c = 0; c < 3; c++) {
    if (actualMin[c] != expectedMin[c] || actualMax[c] != expectedMax[c]) {
      fail(path, 'Position bounds do not match the decoded vertex data.');
    }
  }
}
