import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'independent Khronos Draco Box loads with native attributes and indices',
    () async {
      final scope = AssetScope(
        services: AssetServices(
          resolver: const NativeSourceResolver(),
          meshDecoder: const NativeMeshDecoder(),
        ),
      );
      addTearDown(scope.close);
      final uri = File(
        '../../test_assets/compression/khronos-box/Box.gltf',
      ).absolute.uri;
      final model = await scope.load(Gltf.uri(uri)).result;
      final mesh =
          model.instantiate().children.single.children.single.children.single
              as Mesh;
      expect(mesh.geometry.positions, hasLength(72));
      expect(mesh.geometry.normals, hasLength(72));
      expect(mesh.geometry.indices, hasLength(36));
      expect(model.issues, isEmpty);
    },
  );
}
