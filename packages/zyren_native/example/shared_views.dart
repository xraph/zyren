import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

Future<void> main() async {
  final first = await NativeBackend.create();
  final second = first.createView();
  final mesh = Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0)));
  final scene = Scene()..add(mesh);
  FrameSubmission capture() => FrameSubmission.capture(
    scene: scene,
    camera: PerspectiveCamera(),
    size: PhysicalSize(31, 31),
  );
  try {
    final frames = await Future.wait([
      first.render(capture()),
      second.render(capture()),
    ]);
    final uploaded = frames.fold(
      0,
      (sum, frame) => sum + frame.stats.uploadedBytes,
    );
    if (uploaded != 720) {
      throw StateError('Shared geometry was uploaded twice.');
    }
    print('Two views, one native device, $uploaded geometry bytes uploaded.');
    mesh.visible = false;
    await second.render(capture());
    await first.close();
    final retained = await second.resourceStats();
    if (retained.residentBytes != 720) {
      throw StateError('Hidden geometry was lost.');
    }
    mesh.visible = true;
    final restored = await second.render(capture()) as ReadbackOutput;
    final center = (15 * 31 + 15) * 4;
    final pixel = restored.image.pixels.sublist(center, center + 4);
    if (pixel.join(',') != '255,0,0,255' || restored.stats.uploadedBytes != 0) {
      throw StateError('The surviving view did not retain its red box.');
    }
    print(
      'First view closed; second view restored its red box without upload.',
    );
    scene.remove(mesh);
    await second.render(capture());
    final remaining = (await second.resourceStats()).residentBytes;
    if (remaining != 0) throw StateError('Removed geometry is still resident.');
    print('Final owner removed; $remaining geometry bytes remain.');
  } finally {
    await first.close();
    await second.close();
  }
}
