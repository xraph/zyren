import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'accessor.dart';
import 'checked.dart';
import 'features.dart';
import 'recipes.dart';

const meshFeaturesExtension = 'EXT_mesh_features';

final class _FeatureSet {
  final int? count, nullId, table, tableRows;
  final String? label;
  final bool legacy;
  final DecodedAccessor? attribute;
  const _FeatureSet(
    this.count,
    this.nullId,
    this.table,
    this.tableRows,
    this.label,
    this.legacy,
    this.attribute,
  );
  int? at(int vertex) {
    final id = attribute == null ? vertex : attribute!.values[vertex].toInt();
    return id == nullId ? null : id;
  }
}

List<PrimitiveRecipe> partitionFeatures(
  Map<String, Object?> root,
  Map<String, Object?> primitive,
  Map<String, DecodedAccessor> decoded,
  List<int> originalIndices,
  PrimitiveRecipe recipe,
  DecodeBudget budget,
  int maxPartitions,
  String path,
) {
  final extensions = object(
    field(primitive, 'extensions', <String, Object?>{}),
    '$path.extensions',
  );
  final sets = <_FeatureSet>[];
  if (extensions.containsKey(meshFeaturesExtension)) {
    if (!array(
      field(root, 'extensionsUsed', const []),
      'extensionsUsed',
    ).contains(meshFeaturesExtension)) {
      fail(path, 'Feature IDs require an extensionsUsed declaration.');
    }
    final data = object(
      extensions[meshFeaturesExtension],
      '$path.extensions.$meshFeaturesExtension',
    );
    final ids = array(data['featureIds'], '$path.featureIds');
    if (ids.isEmpty || ids.length > 8) {
      fail(
        path,
        'Feature sets require between one and eight entries.',
        AssetLoadError.limitExceeded,
      );
    }
    final labels = <String>{};
    for (var i = 0; i < ids.length; i++) {
      final p = '$path.featureIds[$i]', id = object(ids[i], p);
      if (id.containsKey('texture')) {
        fail(
          p,
          'Feature texture classification is not supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final count = integer(id['featureCount'], '$p.featureCount', min: 1);
      final nullId = id.containsKey('nullFeatureId')
          ? integer(id['nullFeatureId'], '$p.nullFeatureId', max: 0xffffffff)
          : null;
      final label = id.containsKey('label')
          ? string(id['label'], '$p.label')
          : null;
      if (label != null &&
          (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(label) ||
              !labels.add(label))) {
        fail(p, 'Feature labels must be valid and unique within a primitive.');
      }
      DecodedAccessor? attribute;
      if (id.containsKey('attribute')) {
        final n = integer(id['attribute'], '$p.attribute', max: decoded.length);
        attribute = decoded['_FEATURE_ID_$n'];
        if (attribute == null) fail(p, 'Feature attribute is missing.');
        for (var a = 0; a < n; a++) {
          if (!decoded.containsKey('_FEATURE_ID_$a')) {
            fail(p, 'Feature attribute indices must be consecutive.');
          }
        }
      } else if (count != decoded['POSITION']!.count) {
        fail(p, 'Implicit feature count must equal the vertex count.');
      }
      int? table, rows;
      if (id.containsKey('propertyTable')) {
        final metadata = object(
          object(
            field(root, 'extensions', <String, Object?>{}),
            'extensions',
          )['EXT_structural_metadata'],
          'extensions.EXT_structural_metadata',
        );
        final tables = array(metadata['propertyTables'], 'propertyTables');
        table = index(id['propertyTable'], tables.length, '$p.propertyTable');
        rows = integer(
          object(tables[table], 'propertyTables[$table]')['count'],
          'propertyTables[$table].count',
          min: 1,
        );
        if (count > rows) fail(p, 'Feature count exceeds the property table.');
      }
      sets.add(
        _FeatureSet(count, nullId, table, rows, label, false, attribute),
      );
    }
  }
  if (decoded['_BATCHID'] case final batch?) {
    if (sets.isNotEmpty) {
      fail(
        path,
        'Combined legacy and modern feature sets are unsupported.',
        AssetLoadError.unsupportedFeature,
      );
    }
    sets.add(_FeatureSet(null, null, null, null, null, true, batch));
  }
  if (sets.isEmpty) return [recipe];
  budget.reserve(originalIndices.length * 16 + sets.length * 64, path);
  for (final set in sets) {
    final a = set.attribute;
    if (a != null) {
      if (a.type != 'SCALAR' || a.normalized) {
        fail(path, 'Feature IDs require unnormalized scalar attributes.');
      }
      budget.reserve(a.count * 16, path);
      final unique = <int>{};
      for (final value in a.values) {
        final id = integer(value, path, max: 0xffffffff);
        if (id != set.nullId) {
          unique.add(id);
          if (set.table != null && id >= set.tableRows!) {
            fail(path, 'Feature ID exceeds its property table range.');
          }
        }
      }
      if (set.count != null && unique.length > set.count!) {
        fail(path, 'Feature IDs exceed the declared unique count.');
      }
    }
  }
  final geometry = recipe.geometry;
  final step = switch (geometry.topology) {
    GeometryTopology.triangles => 3,
    GeometryTopology.points => 1,
    _ => 0,
  };
  if (step == 0) {
    fail(
      path,
      'Feature lines are not supported.',
      AssetLoadError.unsupportedFeature,
    );
  }
  final partitions = <String, (List<int?>, List<int>)>{};
  for (var at = 0; at < originalIndices.length; at += step) {
    final ids = [for (final set in sets) set.at(originalIndices[at])];
    for (var c = 1; c < step; c++) {
      for (var s = 0; s < sets.length; s++) {
        if (sets[s].at(originalIndices[at + c]) != ids[s]) {
          fail(
            path,
            'Mixed feature IDs within a triangle need nearest-vertex classification.',
            AssetLoadError.unsupportedFeature,
          );
        }
      }
    }
    final key = ids.join('/');
    if (!partitions.containsKey(key)) {
      if (partitions.length >= maxPartitions) {
        fail(
          path,
          'Feature partitions exceed the primitive limit.',
          AssetLoadError.limitExceeded,
        );
      }
      partitions[key] = (ids, <int>[]);
    }
    final output = partitions[key]!.$2;
    for (var c = 0; c < step; c++) {
      output.add(geometry.indices[at + c]);
    }
  }
  final result = <PrimitiveRecipe>[];
  for (final (ids, indices) in partitions.values) {
    final vertices = <int, int>{};
    for (final index in indices) {
      vertices.putIfAbsent(index, () => vertices.length);
    }
    final attributes = <VertexSemantic, VertexAttribute>{};
    for (final entry in geometry.attributes.entries) {
      final stride = entry.value.format.stride;
      budget.reserve(vertices.length * stride * 2, path);
      final bytes = Uint8List(vertices.length * stride);
      final data = entry.value.data;
      final source = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      for (final vertex in vertices.entries) {
        bytes.setRange(
          vertex.value * stride,
          (vertex.value + 1) * stride,
          source,
          vertex.key * stride,
        );
      }
      final TypedData values = switch (entry.value.format) {
        VertexFormat.uint16x4 => bytes.buffer.asUint16List(),
        VertexFormat.uint32x4 => bytes.buffer.asUint32List(),
        VertexFormat.unorm8x4 => bytes,
        _ => bytes.buffer.asFloat32List(),
      };
      attributes[entry.key] = VertexAttribute(
        values,
        format: entry.value.format,
      );
    }
    List<double>? remapMorph(Float32List? source) {
      if (source == null) return null;
      budget.reserve(vertices.length * 3 * 8, path);
      return [
        for (final vertex in vertices.keys)
          ...source.sublist(vertex * 3, vertex * 3 + 3),
      ];
    }

    final format = vertices.length <= 65536
        ? IndexFormat.uint16
        : IndexFormat.uint32;
    budget.reserve(
      indices.length * (8 + format.bytesPerIndex) + sets.length * 64,
      path,
    );
    result.add(
      PrimitiveRecipe(
        GeometryData(
          attributes: attributes,
          indices: [for (final index in indices) vertices[index]!],
          indexFormat: format,
          topology: geometry.topology,
          morphTargets: [
            for (final target in geometry.morphTargets)
              MorphTarget(
                name: target.name,
                positions: remapMorph(target.positions),
                normals: remapMorph(target.normals),
                tangents: remapMorph(target.tangents),
              ),
          ],
        ),
        recipe.material,
        recipe.name,
        features: [
          for (var s = 0; s < sets.length; s++)
            ModelFeature(
              setIndex: s,
              id: ids[s],
              propertyTable: sets[s].table,
              label: sets[s].label,
              legacyBatch: sets[s].legacy,
            ),
        ],
      ),
    );
  }
  return result;
}
