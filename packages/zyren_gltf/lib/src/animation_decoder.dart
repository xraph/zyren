import 'package:zyren/zyren.dart';
import 'accessor.dart';
import 'animation.dart';
import 'checked.dart';
import 'recipes.dart';

DecodedAccessor _float(
  AccessorReader reader,
  Object? value,
  String type,
  String path,
) {
  final a = reader.read(
    index(
      value,
      array(field(reader.root, 'accessors', const []), 'accessors').length,
      path,
    ),
  );
  if (a.type != type || a.componentType != 5126 || a.normalized) {
    fail(path, 'Expected a float $type accessor.');
  }
  return a;
}

List<ModelSkin> decodeSkins(AccessorReader reader, List<NodeRecipe> nodes) {
  final raw = array(field(reader.root, 'skins', const []), 'skins');
  final skins = <ModelSkin>[];
  for (var i = 0; i < raw.length; i++) {
    final path = 'skins[$i]', skin = object(raw[i], path);
    final joints = [
      for (final joint in array(skin['joints'], '$path.joints'))
        index(joint, nodes.length, '$path.joints'),
    ];
    if (joints.isEmpty || joints.toSet().length != joints.length) {
      fail('$path.joints', 'Skin joints must be nonempty and unique.');
    }
    if (skin.containsKey('skeleton')) {
      index(skin['skeleton'], nodes.length, '$path.skeleton');
    }
    reader.budget.reserve(joints.length * 136, path);
    final matrices = <Mat4>[];
    if (skin.containsKey('inverseBindMatrices')) {
      final a = _float(
        reader,
        skin['inverseBindMatrices'],
        'MAT4',
        '$path.inverseBindMatrices',
      );
      if (a.count < joints.length) {
        fail(path, 'Inverse bind matrix count must match joints.');
      }
      for (var j = 0; j < joints.length; j++) {
        final v = a.values
            .skip(j * 16)
            .take(16)
            .map((v) => v.toDouble())
            .toList();
        if (v[3] != 0 || v[7] != 0 || v[11] != 0 || v[15] != 1) {
          fail(path, 'Inverse bind matrices must be affine.');
        }
        final m = Mat4(v);
        try {
          m.inverted();
        } catch (_) {
          fail(path, 'Inverse bind matrices must be invertible.');
        }
        matrices.add(m);
      }
    } else {
      matrices.addAll([for (final _ in joints) Mat4.identity()]);
    }
    skins.add(ModelSkin(joints, matrices));
  }
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i].skin case final skin?) {
      index(skin, skins.length, 'nodes[$i].skin');
    }
  }
  return List.unmodifiable(skins);
}

List<ModelAnimation> decodeAnimations(
  AccessorReader reader,
  List<NodeRecipe> nodes,
  List<List<PrimitiveRecipe>> meshes,
) {
  final raw = array(field(reader.root, 'animations', const []), 'animations');
  final result = <ModelAnimation>[];
  for (var i = 0; i < raw.length; i++) {
    final path = 'animations[$i]', animation = object(raw[i], path);
    final samplers = array(animation['samplers'], '$path.samplers');
    final rawChannels = array(animation['channels'], '$path.channels');
    if (samplers.isEmpty || rawChannels.isEmpty) {
      fail(path, 'Animation samplers and channels must be nonempty.');
    }
    final channels = <ModelAnimationChannel>[], targets = <(int, String)>{};
    for (var c = 0; c < rawChannels.length; c++) {
      final p = '$path.channels[$c]', channel = object(rawChannels[c], p);
      final target = object(channel['target'], '$p.target');
      final node = index(target['node'], nodes.length, '$p.target.node');
      final property = string(target['path'], '$p.target.path');
      final kind = switch (property) {
        'translation' => ModelAnimationPath.translation,
        'rotation' => ModelAnimationPath.rotation,
        'scale' => ModelAnimationPath.scale,
        'weights' => ModelAnimationPath.weights,
        _ => null,
      };
      if (kind == null) {
        fail('$p.target.path', 'Unknown animation target path.');
      }
      if (!targets.add((node, property))) {
        fail(p, 'Animation channels must target distinct node properties.');
      }
      final rawNode = object(
        array(reader.root['nodes'], 'nodes')[node],
        'nodes[$node]',
      );
      if (rawNode.containsKey('matrix')) {
        fail(p, 'Animation channels require TRS nodes.');
      }
      var components = kind == ModelAnimationPath.rotation ? 4 : 3;
      if (kind == ModelAnimationPath.weights) {
        final mesh = nodes[node].mesh;
        if (mesh == null) fail(p, 'Weight channels require a mesh.');
        components = meshes[mesh].first.deformation?.morphPositions.length ?? 0;
        if (components == 0) fail(p, 'Weight channels require morph targets.');
      }
      final samplerIndex = index(
        channel['sampler'],
        samplers.length,
        '$p.sampler',
      );
      final sp = '$path.samplers[$samplerIndex]',
          sampler = object(samplers[samplerIndex], sp);
      final mode = string(
        field(sampler, 'interpolation', 'LINEAR'),
        '$sp.interpolation',
      );
      final interpolation = switch (mode) {
        'STEP' => ModelInterpolation.step,
        'LINEAR' => ModelInterpolation.linear,
        'CUBICSPLINE' => ModelInterpolation.cubicSpline,
        _ => null,
      };
      if (interpolation == null) fail(sp, 'Unknown animation interpolation.');
      final input = _float(reader, sampler['input'], 'SCALAR', '$sp.input');
      final output = _float(
        reader,
        sampler['output'],
        kind == ModelAnimationPath.weights
            ? 'SCALAR'
            : components == 4
            ? 'VEC4'
            : 'VEC3',
        '$sp.output',
      );
      final factor = interpolation == ModelInterpolation.cubicSpline ? 3 : 1;
      if (output.values.length != input.count * components * factor) {
        fail(sp, 'Animation output count does not match its input.');
      }
      reader.budget.reserve((input.count + output.values.length) * 8, sp);
      final times = input.values.map((v) => v.toDouble()).toList();
      for (var k = 0; k < times.length; k++) {
        if (times[k] < 0 ||
            (k > 0 && times[k] <= times[k - 1]) ||
            times[k] > 86400 * 365) {
          fail(
            '$sp.input',
            'Animation times must increase within a one-year range.',
          );
        }
      }
      final values = output.values.map((v) => v.toDouble()).toList();
      if (kind == ModelAnimationPath.rotation) {
        for (var k = 0; k < times.length; k++) {
          final offset = (k * factor + (factor == 3 ? 1 : 0)) * 4;
          final length = values
              .skip(offset)
              .take(4)
              .fold<double>(0, (sum, v) => sum + v * v);
          if ((length - 1).abs() > 1e-4) {
            fail('$sp.output', 'Rotation keys must be unit quaternions.');
          }
        }
      }
      channels.add(
        ModelAnimationChannel(
          node: node,
          path: kind,
          components: components,
          interpolation: interpolation,
          times: times,
          values: values,
        ),
      );
    }
    final events = <ModelAnimationEvent>[];
    final extras = animation['extras'];
    if (extras is Map && extras.containsKey('zyrenEvents')) {
      final ids = <String>{};
      var previous = -1.0;
      final end = channels.fold<double>(
        0,
        (end, c) => c.times.last > end ? c.times.last : end,
      );
      for (final value in array(
        extras['zyrenEvents'],
        '$path.extras.zyrenEvents',
      )) {
        final event = object(value, '$path.extras.zyrenEvents');
        final time = number(event['time'], path),
            id = string(event['id'], path);
        if (time < 0 ||
            time < previous ||
            time > end ||
            id.trim().isEmpty ||
            !ids.add(id)) {
          fail(
            path,
            'Events need ordered in-range times and unique nonempty IDs.',
          );
        }
        previous = time;
        events.add(
          ModelAnimationEvent(
            Duration(microseconds: (time * 1000000).round()),
            id: id,
            label: event.containsKey('label')
                ? string(event['label'], path)
                : null,
          ),
        );
      }
    }
    result.add(
      ModelAnimation(
        name: animation.containsKey('name')
            ? string(animation['name'], path)
            : null,
        channels: channels,
        events: events,
      ),
    );
  }
  return List.unmodifiable(result);
}

PrimitiveDeformation? decodeDeformation(
  AccessorReader reader,
  Map<String, Object?> primitive,
  int count,
  List<int>? expansion,
  String path,
) {
  final attributes = object(primitive['attributes'], '$path.attributes');
  final targets = array(field(primitive, 'targets', const []), '$path.targets');
  final positions = <List<double>>[],
      normals = <List<double>>[],
      tangents = <List<double>>[];
  List<double> expand(List<double> values, int size) => expansion == null
      ? values
      : [
          for (final vertex in expansion)
            ...values.skip(vertex * size).take(size),
        ];
  final outputCount = expansion?.length ?? count;
  reader.budget.reserve(targets.length * outputCount * 9 * 8, path);
  for (var t = 0; t < targets.length; t++) {
    final target = object(targets[t], '$path.targets[$t]');
    if (target.isEmpty ||
        target.keys.any(
          (k) => !['POSITION', 'NORMAL', 'TANGENT'].contains(k),
        )) {
      fail(path, 'Unknown or empty morph target.');
    }
    for (final (key, list) in [
      ('POSITION', positions),
      ('NORMAL', normals),
      ('TANGENT', tangents),
    ]) {
      var values = List<double>.filled(count * 3, 0);
      if (target.containsKey(key)) {
        if (!attributes.containsKey(key)) {
          fail(path, 'Morph semantics need matching base attributes.');
        }
        final a = _float(reader, target[key], 'VEC3', '$path.targets[$t].$key');
        if (a.count != count) {
          fail(path, 'Morph target counts must match base vertices.');
        }
        values = a.values.map((v) => v.toDouble()).toList();
      }
      list.add(expand(values, 3));
    }
  }
  final joints = <int>[], weights = <double>[];
  final sets = attributes.keys.where((k) => k.startsWith('JOINTS_')).toList()
    ..sort(
      (a, b) => (int.tryParse(a.substring(7)) ?? -1).compareTo(
        int.tryParse(b.substring(7)) ?? -1,
      ),
    );
  if (attributes.keys.where((k) => k.startsWith('WEIGHTS_')).length !=
      sets.length) {
    fail(path, 'Joint and weight sets must pair.');
  }
  for (var set = 0; set < sets.length; set++) {
    if (sets[set] != 'JOINTS_$set' || !attributes.containsKey('WEIGHTS_$set')) {
      fail(path, 'Joint sets must be consecutive and paired.');
    }
  }
  reader.budget.reserve(outputCount * sets.length * 4 * 16, path);
  final jointSets = <DecodedAccessor>[], weightSets = <DecodedAccessor>[];
  for (var set = 0; set < sets.length; set++) {
    final j = reader.read(
      index(
        attributes['JOINTS_$set'],
        array(reader.root['accessors'], 'accessors').length,
        path,
      ),
      usage: AccessorUsage.vertex,
    );
    final w = reader.read(
      index(
        attributes['WEIGHTS_$set'],
        array(reader.root['accessors'], 'accessors').length,
        path,
      ),
      usage: AccessorUsage.vertex,
    );
    if (j.type != 'VEC4' ||
        ![5121, 5123].contains(j.componentType) ||
        j.normalized ||
        j.count != count ||
        w.type != 'VEC4' ||
        w.count != count ||
        !((w.componentType == 5126 && !w.normalized) ||
            ([5121, 5123].contains(w.componentType) && w.normalized))) {
      fail(path, 'Invalid skin vertex attributes.');
    }
    jointSets.add(j);
    weightSets.add(w);
  }
  final vertices = expansion ?? [for (var v = 0; v < count; v++) v];
  for (final vertex in vertices) {
    var sum = 0.0;
    final start = weights.length;
    for (var set = 0; set < sets.length; set++) {
      for (var c = 0; c < 4; c++) {
        final w = weightSets[set].values[vertex * 4 + c].toDouble();
        if (w < 0) fail(path, 'Skin weights must be nonnegative.');
        sum += w;
        joints.add(jointSets[set].values[vertex * 4 + c].toInt());
        weights.add(w);
      }
    }
    if (sets.isNotEmpty) {
      if (sum <= 0) fail(path, 'Skin weights must have positive total.');
      for (var k = start; k < weights.length; k++) {
        weights[k] /= sum;
      }
    }
  }
  if (targets.isEmpty && sets.isEmpty) return null;
  return PrimitiveDeformation(
    morphPositions: positions,
    morphNormals: normals,
    morphTangents: tangents,
    joints: joints,
    weights: weights,
    generatedNormals: expansion != null,
  );
}
