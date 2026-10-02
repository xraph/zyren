import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'material_compiler_test.dart' as fixture;

void main() {
  test(
    'effect frame updates retain revision without requesting another frame',
    () async {
      final device = fixture.Device();
      final shaders = ShaderCompiler(device);
      final materials = MaterialCompiler(device);
      final program = await shaders.compile(ShaderSource.wgsl('valid'));
      final first = await materials.compileEffect(
        PostProcessDescriptor(program: program),
      );
      final second = await materials.compileEffect(
        PostProcessDescriptor(program: program),
      );
      final scene = Scene();
      var changes = 0;
      final subscription = scene.changes.listen((_) => changes++);
      final slot = scene.addEffect(first);
      await Future<void>.delayed(Duration.zero);
      changes = 0;
      final before = scene.revision;
      slot.replace(second, invalidate: false);
      await Future<void>.delayed(Duration.zero);
      expect(scene.effects.single, same(second));
      expect(scene.revision, greaterThan(before));
      expect(changes, 0);
      slot.replace(first);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      slot.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(changes, 2);
      expect(() => slot.replace(second, invalidate: false), throwsStateError);
      await subscription.cancel();
      await materials.close();
      await shaders.close();
    },
  );
}
