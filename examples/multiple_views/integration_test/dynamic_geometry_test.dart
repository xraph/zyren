import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:integration_test/integration_test.dart';

List<int> center(FrameOutput output) => (output as ReadbackOutput).image.pixels
    .sublist((15 * 31 + 15) * 4, (15 * 31 + 15) * 4 + 4);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('dynamic ranges preserve shared native captures and allocation', (
    tester,
  ) async {
    final first = await NativeBackend.create(), second = first.createView();
    final geometry = BufferGeometry(
      dynamic: true,
      indexFormat: IndexFormat.uint16,
      positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2, 0, 2, 3],
      uv0: List.filled(8, .25),
    );
    final mesh = Mesh(
      geometry,
      UnlitMaterial(
        colorMap: TextureMap(
          image: TextureImage.rgba(
            width: 2,
            height: 1,
            pixels: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]),
          ),
        ),
      ),
    );
    final scene = Scene()..add(mesh);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    try {
      final old = capture();
      expect(center(await first.render(old)), [255, 0, 0, 255]);
      await second.render(old);
      geometry.updateAttribute(
        VertexSemantic.uv0,
        Float32List.fromList(List.filled(8, .75)),
      );
      final changed = await first.render(capture());
      expect(changed.stats.uploadedBytes, 64);
      expect(center(changed), [0, 255, 0, 255]);
      expect(center(await second.render(old)), [255, 0, 0, 255]);
      expect((await first.resourceStats()).residentBytes, 352);
      await second.close();
      expect((await first.resourceStats()).residentBytes, 180);
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([1.2, 1, 0]),
        firstVertex: 2,
      );
      geometry.updateAttribute(
        VertexSemantic.normal,
        Float32List.fromList([0, 0, 2]),
        firstVertex: 2,
      );
      final merged = await first.render(capture());
      expect(merged.stats.uploadedBytes, 24);
      expect(center(merged), [0, 255, 0, 255]);
      expect((await first.resourceStats()).residentBytes, 180);
      expect((await first.render(capture())).stats.uploadedBytes, 0);
      scene.remove(mesh);
      await first.render(capture());
      expect((await first.resourceStats()).residentBytes, 0);
    } finally {
      await first.close();
      await second.close();
    }
  });
}
