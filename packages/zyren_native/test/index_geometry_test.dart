import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/draw_cache_accounting.dart';

void main() {
  for (final format in IndexFormat.values) {
    test(
      '${format.name} native draw and copied dynamic version preserve odd index counts',
      () async {
        final first = await NativeBackend.create(), second = first.createView();
        final geometry = BufferGeometry(
          positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2],
          indexFormat: format,
          dynamic: true,
        );
        final scene = Scene()
          ..background = const Color3(0, 0, 0)
          ..add(Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))));
        FrameSubmission capture() => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(31, 31),
        );
        List<int> center(FrameOutput output) => (output as ReadbackOutput)
            .image
            .pixels
            .sublist((15 * 31 + 15) * 4, (15 * 31 + 15) * 4 + 4);
        final bytes = 72 + 3 * format.bytesPerIndex;
        try {
          final old = capture();
          final initial = await first.render(old);
          expect(center(initial), [255, 0, 0, 255]);
          expect(initial.stats.uploadedBytes, bytes);
          await second.render(old);
          geometry.updateAttribute(
            VertexSemantic.position,
            Float32List.fromList([19, -1, 0, 21, -1, 0, 20, 1, 0]),
          );
          final changed = await first.render(capture());
          expect(changed.stats.uploadedBytes, 72);
          expect(center(changed), [0, 0, 0, 255]);
          expect((await sceneAssetPayloadBytes(first)), bytes * 2);
          expect(center(await second.render(old)), [255, 0, 0, 255]);
          await second.close();
          expect((await sceneAssetPayloadBytes(first)), bytes);
          scene.remove(scene.children.single);
          await first.render(capture());
          expect((await first.resourceStats()).residentBytes, 0);
        } finally {
          await first.close();
          await second.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
