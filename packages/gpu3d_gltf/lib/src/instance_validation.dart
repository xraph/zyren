import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'checked.dart';
import 'recipes.dart';

/// Bound the expanded scene, including repeated references to the same mesh.
void validateInstances(
  List<NodeRecipe> nodes,
  List<SceneRecipe> scenes,
  List<Object?> meshes,
  int limit,
) {
  final primitiveCounts = [
    for (var i = 0; i < meshes.length; i++)
      array(
        object(meshes[i], 'meshes[$i]')['primitives'],
        'meshes[$i].primitives',
      ).length,
  ];
  final counts = List<int?>.filled(nodes.length, null);
  int count(int node) => counts[node] ??=
      ((nodes[node].mesh == null ? 0 : primitiveCounts[nodes[node].mesh!]) +
      nodes[node].children.fold<int>(0, (sum, child) => sum + count(child)));
  for (var i = 0; i < scenes.length; i++) {
    if (scenes[i].roots.fold<int>(0, (sum, root) => sum + count(root)) >
        limit) {
      fail(
        'scenes[$i]',
        'Instantiated mesh count exceeds the primitive limit.',
        AssetLoadError.limitExceeded,
      );
    }
  }
  final children = {for (final node in nodes) ...node.children};
  void visit(int index, Mat4 parent) {
    final node = nodes[index], path = 'nodes[$index]';
    late final Mat4 world;
    try {
      world = parent * Mat4.compose(node.position, node.rotation, node.scale);
    } on ArgumentError {
      fail(
        path,
        'World transform exceeds finite storage.',
        AssetLoadError.unsupportedFeature,
      );
    }
    if (node.mesh != null) {
      final packed = Float32List.fromList(world.storage);
      if (packed.any((value) => !value.isFinite)) {
        fail(
          path,
          'World transform exceeds native float32 storage.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final determinant = Mat4(packed).toVectorMath().determinant();
      if (!determinant.isFinite ||
          determinant.abs() < 1e-20 ||
          determinant.abs() > 3.4028234663852886e38) {
        fail(
          path,
          'World transform cannot be inverted by the native renderer.',
          AssetLoadError.unsupportedFeature,
        );
      }
    }
    for (final child in node.children) {
      visit(child, world);
    }
  }

  // Graph validation already established acyclic, single-parent trees.
  for (var i = 0; i < nodes.length; i++) {
    if (!children.contains(i)) visit(i, Mat4.identity());
  }
}
