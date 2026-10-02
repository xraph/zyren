import 'dart:io';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:model_viewer/model_bounds.dart';

final class _Source implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(
        effectiveUri: uri,
        bytes: await File('assets/models/deformation.glb').readAsBytes(),
      );
}

void main() {
  test('viewer framing contains every imported deformed vertex', () async {
    final scope = AssetScope(services: AssetServices(resolver: _Source()));
    try {
      final model = (await scope.load(Gltf.asset('deformation.glb')).result)
          .instantiate();
      model.nodes[3]!.position = const Vec3(100, 0, 0);
      model.mixer
          .play(model.animations.single)
          .seek(const Duration(seconds: 1));
      final bounds = await modelBounds(model, () => false);
      expect(bounds.center.x.abs(), lessThan(2));
      for (final index in [3, 6]) {
        final mesh = model.nodes[index]!.children
            .whereType<SkinnedMesh>()
            .single;
        final m = mesh.worldMatrix.storage;
        for (var i = 0; i < mesh.geometry.vertexCount; i++) {
          final p = mesh.vertexPosition(i);
          final world = Vec3(
            m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
            m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
            m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
          );
          expect(
            (world - bounds.center).length,
            lessThanOrEqualTo(bounds.radius + 1e-6),
          );
        }
      }
    } finally {
      await scope.close();
    }
  });
}
