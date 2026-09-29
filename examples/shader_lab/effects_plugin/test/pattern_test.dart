import 'package:zyren/zyren.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';
import 'effects_test.dart' show UnsupportedBackend;

void main() {
  test('pattern frequency is bounded before changing the material', () {
    final mesh = Mesh(BoxGeometry(), DiffuseMaterial());
    final pattern = PatternMaterialPlugin(mesh);
    for (final value in [double.nan, double.infinity, 0.0, 17.0]) {
      expect(() => pattern.frequency = value, throwsArgumentError);
    }
    expect(pattern.frequency, 8);
  });
  test(
    'explicit bypass keeps the original material on an unsupported device',
    () async {
      final mesh = Mesh(BoxGeometry(), DiffuseMaterial());
      final original = mesh.material;
      final backend = UnsupportedBackend();
      final engine = await SceneEngine.create(
        scene: Scene()..add(mesh),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          PatternMaterialPlugin(mesh, unsupported: UnsupportedEffects.bypass),
        ],
      );
      expect(mesh.material, same(original));
      await engine.dispose();
      expect(mesh.material, same(original));
    },
  );
}
