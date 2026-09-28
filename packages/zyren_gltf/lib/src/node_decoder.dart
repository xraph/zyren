import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'limits.dart';
import 'recipes.dart';

(List<NodeRecipe>, List<SceneRecipe>, int?) decodeNodes(
  Map<String, Object?> root,
  GltfLimits limits,
  int meshCount,
) {
  final rawNodes = array(field(root, 'nodes', const []), 'nodes');
  if (rawNodes.length > limits.maxNodes) {
    fail(
      'nodes',
      'Node count exceeds its limit.',
      AssetLoadError.limitExceeded,
    );
  }
  final nodes = <NodeRecipe>[];
  final parents = List<int?>.filled(rawNodes.length, null);
  for (var i = 0; i < rawNodes.length; i++) {
    final path = 'nodes[$i]', node = object(rawNodes[i], 'nodes[$i]');
    for (final key in ['skin', 'weights', 'camera']) {
      if (node.containsKey(key)) {
        fail(
          '$path.$key',
          'This node feature is not supported by the static model profile.',
          AssetLoadError.unsupportedFeature,
        );
      }
    }
    final name = node.containsKey('name')
        ? string(node['name'], '$path.name')
        : null;
    final mesh = node.containsKey('mesh')
        ? index(node['mesh'], meshCount, '$path.mesh')
        : null;
    final children = <int>[];
    if (node.containsKey('children')) {
      final raw = array(node['children'], '$path.children');
      if (raw.isEmpty) {
        fail('$path.children', 'Child arrays must be nonempty when present.');
      }
      for (var j = 0; j < raw.length; j++) {
        final child = index(raw[j], rawNodes.length, '$path.children[$j]');
        if (parents[child] != null) {
          fail(
            '$path.children[$j]',
            'A node cannot have repeated or multiple parents.',
          );
        }
        parents[child] = i;
        children.add(child);
      }
    }
    var position = Vec3.zero, rotation = Quat.identity, scale = Vec3.one;
    if (node.containsKey('matrix')) {
      if (['translation', 'rotation', 'scale'].any(node.containsKey)) {
        fail(path, 'Choose a matrix or TRS components, not both.');
      }
      final values = numbers(node['matrix'], 16, '$path.matrix');
      if (values[3] != 0 ||
          values[7] != 0 ||
          values[11] != 0 ||
          values[15] != 1) {
        fail('$path.matrix', 'Node matrices must be affine.');
      }
      final matrix = Mat4(values).toVectorMath();
      final t = Vec3.zero.toVectorMath(),
          r = Quat.identity.toVectorMath(),
          s = Vec3.one.toVectorMath();
      if (matrix.determinant() == 0) {
        fail(
          '$path.matrix',
          'Singular node transforms are not yet supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      matrix.decompose(t, r, s);
      if (!t.storage.every((v) => v.isFinite) ||
          !s.storage.every((v) => v.isFinite) ||
          !r.length2.isFinite ||
          r.length2 < 1e-30) {
        fail('$path.matrix', 'Node matrix decomposition is not finite.');
      }
      position = Vec3.fromVectorMath(t);
      rotation = Quat.fromVectorMath(r).normalized();
      scale = Vec3.fromVectorMath(s);
      final roundTrip = Mat4.compose(position, rotation, scale).storage;
      for (var at = 0; at < 16; at++) {
        if ((roundTrip[at] - values[at]).abs() >
            1e-6 * (1 + values[at].abs())) {
          fail(
            '$path.matrix',
            'Node matrices must decompose into translation, rotation and scale.',
          );
        }
      }
    } else {
      if (node.containsKey('translation')) {
        final v = numbers(node['translation'], 3, '$path.translation');
        position = Vec3(v[0], v[1], v[2]);
      }
      if (node.containsKey('rotation')) {
        final v = numbers(node['rotation'], 4, '$path.rotation');
        final length2 = v.fold<double>(0, (sum, value) => sum + value * value);
        if ((length2 - 1).abs() > 1e-4) {
          fail('$path.rotation', 'Node rotation must be a unit quaternion.');
        }
        rotation = Quat(v[0], v[1], v[2], v[3]).normalized();
      }
      if (node.containsKey('scale')) {
        final v = numbers(node['scale'], 3, '$path.scale');
        scale = Vec3(v[0], v[1], v[2]);
      }
    }
    if (scale.x == 0 || scale.y == 0 || scale.z == 0) {
      fail(
        '$path.scale',
        'Singular node transforms are not yet supported.',
        AssetLoadError.unsupportedFeature,
      );
    }
    nodes.add(
      NodeRecipe(
        name,
        position,
        rotation,
        scale,
        mesh,
        List.unmodifiable(children),
      ),
    );
  }
  final state = List<int>.filled(nodes.length, 0);
  void visit(int node, int depth) {
    if (state[node] == 1) {
      fail('nodes[$node].children', 'Node hierarchy contains a cycle.');
    }
    if (depth > limits.maxNodeDepth) {
      fail(
        'nodes[$node]',
        'Node depth exceeds its limit.',
        AssetLoadError.limitExceeded,
      );
    }
    if (state[node] == 2) return;
    state[node] = 1;
    for (final child in nodes[node].children) {
      visit(child, depth + 1);
    }
    state[node] = 2;
  }

  for (var i = 0; i < nodes.length; i++) {
    if (parents[i] == null) visit(i, 1);
  }
  for (var i = 0; i < nodes.length; i++) {
    if (state[i] == 0) visit(i, 1);
  }
  final rawScenes = array(field(root, 'scenes', const []), 'scenes');
  final scenes = <SceneRecipe>[];
  for (var i = 0; i < rawScenes.length; i++) {
    final path = 'scenes[$i]', scene = object(rawScenes[i], 'scenes[$i]');
    final raw = array(field(scene, 'nodes', const []), '$path.nodes');
    if (scene.containsKey('nodes') && raw.isEmpty) {
      fail('$path.nodes', 'Root arrays must be nonempty when present.');
    }
    final roots = <int>[];
    final seenRoots = <int>{};
    for (var j = 0; j < raw.length; j++) {
      final node = index(raw[j], nodes.length, '$path.nodes[$j]');
      if (parents[node] != null || !seenRoots.add(node)) {
        fail('$path.nodes[$j]', 'Scene roots must be unique parentless nodes.');
      }
      roots.add(node);
    }
    scenes.add(
      SceneRecipe(
        scene.containsKey('name') ? string(scene['name'], '$path.name') : null,
        List.unmodifiable(roots),
      ),
    );
  }
  final selected = root.containsKey('scene')
      ? index(root['scene'], scenes.length, 'scene')
      : null;
  return (List.unmodifiable(nodes), List.unmodifiable(scenes), selected);
}

List<double> numbers(Object? value, int count, String path) {
  final values = array(value, path);
  if (values.length != count) fail(path, 'Expected $count components.');
  return [for (var i = 0; i < count; i++) number(values[i], '$path[$i]')];
}
