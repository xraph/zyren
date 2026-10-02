import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:test/test.dart';
import 'geometry_model_test.dart' show onlyMesh;
import 'model_test.dart' show load;
import 'support/fixtures.dart';

void main() {
  for (final type in [5126, 5121, 5123]) {
    for (final components in [3, 4]) {
      test(
        'COLOR_0 $type VEC$components survives flat-normal expansion',
        () async {
          final model = await load(
            primitiveModel(
              indices: [0, 1, 2, 0, 2, 3],
              colors: [
                for (var i = 0; i < 4; i++) ...[
                  i / 3,
                  .5,
                  1,
                  if (components == 4) i / 3,
                ],
              ],
              colorComponents: components,
              colorComponentType: type,
            ),
          );
          final mesh = onlyMesh(model);
          expect(mesh.material.vertexColors, isTrue);
          expect(mesh.geometry.vertexCount, 6);
          final values = mesh.geometry.colors!;
          final tolerance = type == 5121 ? 1 / 255 : 1 / 65535;
          for (var i = 0; i < 6; i++) {
            final source = [0, 1, 2, 0, 2, 3][i];
            expect(values[i * 4], closeTo(source / 3, tolerance));
            expect(values[i * 4 + 1], closeTo(.5, tolerance));
            expect(values[i * 4 + 2], 1);
            expect(
              values[i * 4 + 3],
              closeTo(components == 3 ? 1 : source / 3, tolerance),
            );
          }
          expect(model.issues, isEmpty);
        },
      );
    }
  }
  test('floating colors clamp to glTF limits', () async {
    final mesh = onlyMesh(
      await load(
        primitiveModel(
          indices: [0, 1, 2],
          colors: [
            for (var i = 0; i < 4; i++) ...[-.5, 1.5, .5, 2],
          ],
        ),
      ),
    );
    expect(mesh.geometry.colors, [
      for (var i = 0; i < 3; i++) ...[0, 1, .5, 1],
    ]);
  });
  test(
    'color accessors reject unsigned values without normalization',
    () async {
      final bytes = editModel(
        primitiveModel(
          indices: [0, 1, 2],
          colorComponentType: 5121,
          colors: List.filled(16, 1),
        ),
        (root) {
          (root['accessors'] as List)[1].remove('normalized');
        },
      );
      await expectLater(
        load(bytes),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.invalidData)
              .having((e) => e.fieldPath, 'path', endsWith('COLOR_0')),
        ),
      );
    },
  );
  test('PBR, diagnostic, points and lines retain vertex colors', () async {
    for (final mode in [0, 1, 3, 4]) {
      final mesh = onlyMesh(
        await load(
          primitiveModel(
            indices: mode == 4 ? [0, 1, 2] : null,
            mode: mode,
            colors: List.filled(16, .5),
          ),
        ),
      );
      expect(mesh.material.vertexColors, isTrue);
      expect(mesh.geometry.colors, isNotNull);
    }
    final bytes = editModel(
      primitiveModel(
        indices: [0, 1, 2],
        normals: [
          for (var i = 0; i < 4; i++) ...[0, 0, 1],
        ],
        colors: List.filled(16, .5),
      ),
      (root) {
        (root['materials'] as List).first.remove('extensions');
      },
    );
    expect(
      onlyMesh(await load(bytes)).material,
      isA<StandardMaterial>().having((m) => m.vertexColors, 'colors', true),
    );
    expect(
      onlyMesh(
        await load(
          bytes,
          options: const GltfOptions(
            materialMode: GltfMaterialMode.unlitDiagnostic,
          ),
        ),
      ).material.vertexColors,
      isTrue,
    );
  });
  test('shared material enables color separately for each primitive', () async {
    final bytes = editModel(
      primitiveModel(indices: [0, 1, 2], colors: List.filled(16, 1)),
      (root) {
        final primitives = (root['meshes'] as List).first['primitives'] as List;
        final first = primitives.single as Map;
        primitives.add({
          ...first,
          'attributes': {...first['attributes'] as Map}..remove('COLOR_0'),
        });
      },
    );
    final root = (await load(bytes)).instantiate();
    final meshes = <Mesh>[];
    void collect(Object3D object) {
      if (object is Mesh) meshes.add(object);
      for (final child in object.children) {
        collect(child);
      }
    }

    collect(root);
    expect(meshes.map((m) => m.material.vertexColors), [true, false]);
  });
}
