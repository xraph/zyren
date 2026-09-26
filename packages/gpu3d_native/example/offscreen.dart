import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';

Future<void> main() async {
  final backend = await NativeBackend.create();
  try {
    final scene = Scene()
      ..add(
        Mesh(
          BoxGeometry(),
          MeshMaterial(color: const Color3(1, 0, 0), unlit: true),
        ),
      );
    final output = await backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(63, 47),
      ),
    );
    switch (output) {
      case ReadbackOutput(:final image, :final stats):
        final center = (23 * image.size.width + 31) * 4;
        print(
          '${image.size.width}x${image.size.height} native frame, '
          '${stats.triangles} triangles, center RGBA: '
          '${image.pixels.sublist(center, center + 4)}',
        );
      case PresentedOutput():
        throw StateError('This example requests CPU readback.');
    }
  } finally {
    await backend.close();
  }
}
