import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'accessor.dart';
import 'checked.dart';
import 'recipes.dart';

List<List<double>> decodeMorphDefaults(
  List<Object?> meshes,
  DecodeBudget budget,
) {
  return [
    for (var i = 0; i < meshes.length; i++)
      _meshWeights(object(meshes[i], 'meshes[$i]'), 'meshes[$i]', budget),
  ];
}

List<double> _meshWeights(
  Map<String, Object?> mesh,
  String path,
  DecodeBudget budget,
) {
  var count = 0;
  final primitives = array(mesh['primitives'], '$path.primitives');
  for (var p = 0; p < primitives.length; p++) {
    final primitive = object(primitives[p], '$path.primitives[$p]');
    if (!primitive.containsKey('targets')) continue;
    final targets = array(primitive['targets'], '$path.primitives[$p].targets');
    if (targets.isEmpty) {
      fail(
        '$path.primitives[$p].targets',
        'Targets must be nonempty when present.',
      );
    }
    if (targets.length > 64) {
      fail(
        '$path.primitives[$p].targets',
        'Native meshes support at most 64 morph targets.',
        AssetLoadError.limitExceeded,
      );
    }
    if (count != 0 && count != targets.length) {
      fail(path, 'Morph target counts must match across primitives.');
    }
    count = targets.length;
  }
  budget.reserve(count * 8, '$path.weights');
  if (!mesh.containsKey('weights')) return List.filled(count, 0);
  if (count == 0) fail('$path.weights', 'Weights require morph targets.');
  final weights = numbers(mesh['weights'], count, '$path.weights');
  if (weights.any((v) => v.abs() > 1e6)) {
    fail(
      '$path.weights',
      'Morph weight magnitude exceeds 1e6.',
      AssetLoadError.limitExceeded,
    );
  }
  return List.unmodifiable(weights);
}

void validateJointAccessor(DecodedAccessor a, String semantic, String path) {
  final valid = semantic == 'JOINTS_0'
      ? [5121, 5123].contains(a.componentType) && !a.normalized
      : (a.componentType == 5126 && !a.normalized) ||
            ([5121, 5123].contains(a.componentType) && a.normalized);
  if (a.type != 'VEC4' || !valid) {
    fail(
      path,
      'Joints require unsigned VEC4; weights require float or normalized unsigned VEC4.',
    );
  }
}

void decodeJointAttributes(
  Map<String, DecodedAccessor> decoded,
  Map<VertexSemantic, VertexAttribute> output,
  List<int>? remap,
  DecodeBudget budget,
  String path,
) {
  final joints = decoded['JOINTS_0'], weights = decoded['WEIGHTS_0'];
  if ((joints == null) != (weights == null)) {
    fail('$path.attributes', 'Joint and weight attributes must be paired.');
  }
  if (joints == null || weights == null) return;
  final count = remap?.length ?? joints.count;
  budget.reserve(count * 24 * 2, path);
  final jointValues = Uint16List(count * 4),
      weightValues = Float32List(count * 4);
  for (var i = 0; i < count; i++) {
    final src = (remap?[i] ?? i) * 4;
    var sum = 0.0;
    final active = <int>{};
    for (var j = 0; j < 4; j++) {
      final weight = weights.values[src + j].toDouble();
      final joint = joints.values[src + j].toInt();
      if (weight < 0 || (weight > 0 && !active.add(joint))) {
        fail(
          '$path.attributes.WEIGHTS_0',
          'Joint influences must be nonnegative and nonzero influences cannot repeat a joint.',
        );
      }
      sum += weight;
      jointValues[i * 4 + j] = joint;
    }
    if (sum <= 0 || !sum.isFinite) {
      fail(
        '$path.attributes.WEIGHTS_0',
        'Each vertex needs a positive finite sum of joint weights.',
      );
    }
    if (weights.normalized && (sum - 1).abs() > 8e-7) {
      fail(
        '$path.attributes.WEIGHTS_0',
        'Quantized joint weights must sum to one.',
      );
    }
    for (var j = 0; j < 4; j++) {
      weightValues[i * 4 + j] = weights.values[src + j] / sum;
    }
  }
  output[VertexSemantic.joints] = VertexAttribute(
    jointValues,
    format: VertexFormat.uint16x4,
  );
  output[VertexSemantic.weights] = VertexAttribute(
    weightValues,
    format: VertexFormat.float32x4,
  );
}

List<MorphTarget> decodeMorphTargets(
  Map<String, Object?> root,
  Map<String, Object?> primitive,
  Map<String, Object?> mesh,
  Map<String, DecodedAccessor> base,
  AccessorReader reader,
  List<int>? remap,
  String path,
  void Function(num, DecodedAccessor) positionBounds,
) {
  final targets = array(field(primitive, 'targets', const []), '$path.targets');
  final accessors = array(field(root, 'accessors', const []), 'accessors');
  final extras = mesh['extras'];
  final names = extras is Map && extras['targetNames'] is List
      ? extras['targetNames'] as List
      : const [];
  final result = <MorphTarget>[];
  for (var t = 0; t < targets.length; t++) {
    final tp = '$path.targets[$t]',
        target = object(targets[t], '$path.targets[$t]');
    if (target.isEmpty) {
      fail(tp, 'Morph targets must contain a delta attribute.');
    }
    final data = <String, Float32List>{};
    for (final entry in target.entries) {
      final ap = '$tp.${entry.key}';
      if (!base.containsKey(entry.key)) {
        fail(ap, 'Morph attributes require a matching base attribute.');
      }
      if (!['POSITION', 'NORMAL', 'TANGENT'].contains(entry.key)) {
        fail(
          ap,
          'Native morph targets support position, normal and tangent deltas.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final a = reader.read(
        index(entry.value, accessors.length, ap),
        usage: AccessorUsage.vertex,
      );
      if (a.type != 'VEC3' ||
          a.componentType != 5126 ||
          a.normalized ||
          a.count != base['POSITION']!.count) {
        fail(
          ap,
          'Morph deltas require float VEC3 accessors matching the base vertex count.',
        );
      }
      if (entry.key == 'POSITION') {
        positionBounds(entry.value as num, a);
      }
      if (entry.key == 'TANGENT' && !base.containsKey('NORMAL')) {
        fail(
          ap,
          'Morphed tangents require base normals.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final count = remap?.length ?? a.count;
      reader.budget.reserve(count * 12 * (remap == null ? 1 : 2), ap);
      final values = a.data as Float32List;
      final packed = remap == null ? values : Float32List(count * 3);
      if (remap != null) {
        for (var i = 0; i < count; i++) {
          for (var c = 0; c < 3; c++) {
            packed[i * 3 + c] = values[remap[i] * 3 + c];
          }
        }
      }
      data[entry.key] = packed;
    }
    result.add(
      MorphTarget(
        name: names.length == targets.length && names[t] is String
            ? names[t] as String
            : null,
        positions: data['POSITION'],
        normals: data['NORMAL'],
        tangents: data['TANGENT'],
      ),
    );
  }
  return List.unmodifiable(result);
}

List<SkinRecipe> decodeSkins(
  Map<String, Object?> root,
  List<NodeRecipe> nodes,
  List<SceneRecipe> scenes,
  List<List<PrimitiveRecipe>> meshes,
  AccessorReader reader,
) {
  final raw = array(field(root, 'skins', const []), 'skins');
  final accessors = array(field(root, 'accessors', const []), 'accessors');
  final parents = <int, int>{
    for (var i = 0; i < nodes.length; i++)
      for (final c in nodes[i].children) c: i,
  };
  List<int> ancestors(int i) => [
    i,
    if (parents[i] case final parent?) ...ancestors(parent),
  ];
  final skins = <SkinRecipe>[];
  for (var s = 0; s < raw.length; s++) {
    final path = 'skins[$s]', skin = object(raw[s], 'skins[$s]');
    final refs = array(skin['joints'], '$path.joints');
    if (refs.isEmpty) fail('$path.joints', 'Skins need joints.');
    if (refs.length > 256) {
      fail(
        '$path.joints',
        'Native skins support at most 256 joints.',
        AssetLoadError.limitExceeded,
      );
    }
    reader.budget.reserve(refs.length * 144, path);
    final joints = [
      for (var j = 0; j < refs.length; j++)
        index(refs[j], nodes.length, '$path.joints[$j]'),
    ];
    if (joints.toSet().length != joints.length) {
      fail('$path.joints', 'Skin joints must be unique.');
    }
    var common = ancestors(joints.first).toSet();
    for (final joint in joints.skip(1)) {
      common = common.intersection(ancestors(joint).toSet());
    }
    if (common.isEmpty) fail('$path.joints', 'Skin joints need a common root.');
    if (skin.containsKey('skeleton') &&
        !common.contains(
          index(skin['skeleton'], nodes.length, '$path.skeleton'),
        )) {
      fail(
        '$path.skeleton',
        'Skeleton must be a common ancestor of every joint.',
      );
    }
    final matrices = <Mat4>[];
    if (skin.containsKey('inverseBindMatrices')) {
      final a = reader.read(
        index(
          skin['inverseBindMatrices'],
          accessors.length,
          '$path.inverseBindMatrices',
        ),
        usage: AccessorUsage.skin,
      );
      if (a.type != 'MAT4' ||
          a.componentType != 5126 ||
          a.normalized ||
          a.count < joints.length) {
        fail(
          '$path.inverseBindMatrices',
          'Inverse binds require at least one float MAT4 per joint.',
        );
      }
      for (var j = 0; j < joints.length; j++) {
        final matrix = Mat4(
          a.values.skip(j * 16).take(16).map((v) => v.toDouble()).toList(),
        );
        final v = matrix.storage;
        if (v[3] != 0 || v[7] != 0 || v[11] != 0 || v[15] != 1) {
          fail('$path.inverseBindMatrices', 'Inverse binds must be affine.');
        }
        try {
          matrix.inverted();
        } on ArgumentError {
          fail(
            '$path.inverseBindMatrices',
            'Inverse binds must have finite inverses.',
            AssetLoadError.unsupportedFeature,
          );
        }
        if (matrix.toVectorMath().determinant() == 0) {
          fail(
            '$path.inverseBindMatrices',
            'Singular inverse binds are unsupported.',
            AssetLoadError.unsupportedFeature,
          );
        }
        matrices.add(matrix);
      }
    } else {
      matrices.addAll([for (final _ in joints) Mat4.identity()]);
    }
    skins.add(
      SkinRecipe(List.unmodifiable(joints), List.unmodifiable(matrices)),
    );
  }
  final maxima = <List<int?>>[
    for (final mesh in meshes)
      [
        for (final primitive in mesh)
          primitive.geometry.attributes[VertexSemantic.joints] == null
              ? null
              : (primitive.geometry.attributes[VertexSemantic.joints]!.data
                        as List<int>)
                    .fold<int>(0, (a, b) => a > b ? a : b),
      ],
  ];
  for (var n = 0; n < nodes.length; n++) {
    final node = nodes[n];
    if (node.skin == null) continue;
    final skin = skins[node.skin!];
    for (final maximum in maxima[node.mesh!]) {
      if (maximum == null) {
        fail(
          'nodes[$n].skin',
          'Every skinned primitive needs joint and weight attributes.',
        );
      }
      if (maximum >= skin.joints.length) {
        fail('nodes[$n].skin', 'A vertex joint index exceeds the bound skin.');
      }
    }
  }
  for (var s = 0; s < scenes.length; s++) {
    final members = <int>{};
    void visit(int i) {
      members.add(i);
      for (final c in nodes[i].children) {
        visit(c);
      }
    }

    for (final root in scenes[s].roots) {
      visit(root);
    }
    for (final node in members) {
      if (nodes[node].skin case final skin?) {
        if (!skins[skin].joints.every(members.contains)) {
          fail(
            'scenes[$s]',
            'A skinned mesh and all its joints must belong to the same scene.',
          );
        }
      }
    }
  }
  return List.unmodifiable(skins);
}

List<MorphTarget> generateMorphNormals(
  List<MorphTarget> targets,
  Float32List positions,
  Float32List normals,
  DecodeBudget budget,
  String path,
) {
  return [
    for (final target in targets)
      _flatMorphNormals(target, positions, normals, budget, path),
  ];
}

MorphTarget _flatMorphNormals(
  MorphTarget target,
  Float32List positions,
  Float32List normals,
  DecodeBudget budget,
  String path,
) {
  final delta = target.positions;
  if (delta == null) return target;
  budget.reserve(target.byteLength + normals.lengthInBytes * 2, path);
  final normalDelta = Float32List(normals.length);
  for (var i = 0; i < positions.length; i += 9) {
    Vec3 point(int at) => Vec3(
      positions[at] + delta[at],
      positions[at + 1] + delta[at + 1],
      positions[at + 2] + delta[at + 2],
    );
    final a = point(i), cross = (point(i + 3) - a).cross(point(i + 6) - a);
    final normal = cross.length2 == 0
        ? Vec3(normals[i], normals[i + 1], normals[i + 2])
        : cross.normalized();
    for (var at = i; at < i + 9; at += 3) {
      normalDelta[at] = normal.x - normals[at];
      normalDelta[at + 1] = normal.y - normals[at + 1];
      normalDelta[at + 2] = normal.z - normals[at + 2];
    }
  }
  return MorphTarget(
    name: target.name,
    positions: delta,
    normals: normalDelta,
    tangents: target.tangents,
  );
}
