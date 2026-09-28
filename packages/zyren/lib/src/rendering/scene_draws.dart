part of 'frame_submission.dart';

int _countDraws(SceneSnapshot scene) {
  if (!scene._meshes.any((m) => (m['instances'] as List).isNotEmpty)) {
    return scene._meshes.length;
  }
  final order = <({int mesh, int slot, bool mirror, double depth})>[];
  final vp = vm.Matrix4.fromList(scene._viewProjection);
  for (var index = 0; index < scene._meshes.length; index++) {
    final mesh = scene._meshes[index];
    final instances = (mesh['instances'] as List).cast<double>();
    var center = vm.Vector3.zero();
    if (mesh['alpha_mode'] == 2) {
      final positions = scene._geometries[mesh['geometry']]!.positions;
      final low = vm.Vector3.all(double.infinity),
          high = vm.Vector3.all(-double.infinity);
      for (var i = 0; i < positions.length; i += 3) {
        for (var c = 0; c < 3; c++) {
          low[c] = math.min(low[c], positions[i + c]);
          high[c] = math.max(high[c], positions[i + c]);
        }
      }
      center = (low + high) * .5;
    }
    final count = instances.isEmpty ? 1 : instances.length ~/ 16;
    for (var slot = 0; slot < count; slot++) {
      final model = vm.Matrix4.fromList(
        instances.isEmpty
            ? (mesh['model'] as List).cast<double>()
            : instances.sublist(slot * 16, slot * 16 + 16),
      );
      final clip = (vp * model).transform(
        vm.Vector4(center.x, center.y, center.z, 1),
      );
      order.add((
        mesh: index,
        slot: slot,
        mirror: model.determinant() < 0,
        depth: clip.w.abs() > 1e-20 ? clip.z / clip.w : clip.z,
      ));
    }
  }
  order.sort((a, b) {
    final left = scene._meshes[a.mesh], right = scene._meshes[b.mesh];
    final blend = left['alpha_mode'] == 2;
    var result = (blend ? 1 : 0).compareTo(right['alpha_mode'] == 2 ? 1 : 0);
    if (result == 0) {
      result = (left['render_order'] as int).compareTo(
        right['render_order'] as int,
      );
    }
    if (result == 0 && blend) {
      result = scene._depthStrategy == DepthStrategy.reversed
          ? a.depth.compareTo(b.depth)
          : b.depth.compareTo(a.depth);
    }
    if (result == 0) result = a.mesh.compareTo(b.mesh);
    if (result == 0 && !blend) {
      result = (a.mirror ? 1 : 0).compareTo(b.mirror ? 1 : 0);
    }
    return result == 0 ? a.slot.compareTo(b.slot) : result;
  });
  var count = 0, previous = -1;
  bool? mirror;
  for (final draw in order) {
    if (previous != draw.mesh || mirror != draw.mirror) count++;
    previous = draw.mesh;
    mirror = draw.mirror;
  }
  return count;
}
