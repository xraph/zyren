import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'material_compiler_test.dart' show Device;

void main() {
  test('custom shader clipping requires an explicit hook contract', () async {
    final device = Device();
    final compiler = MaterialCompiler(device);
    final programs = ShaderCompiler(device);
    try {
      final program = await programs.compile(ShaderSource.wgsl('valid'));
      for (final supported in [false, true]) {
        final shader = await compiler.compile(
          MeshShaderDescriptor(program: program, supportsClipping: supported),
        );
        final scene = Scene()
          ..clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
        final mesh = scene.add(Mesh(PlaneGeometry(), ShaderMaterial(shader)));
        FrameSubmission capture() => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(8, 8),
        );
        if (supported) {
          expect(capture, returnsNormally);
        } else {
          expect(capture, throwsUnsupportedError);
        }
        mesh.clippingEnabled = false;
        expect(capture, returnsNormally);
      }
    } finally {
      await compiler.close();
      await programs.close();
    }
  });
}
