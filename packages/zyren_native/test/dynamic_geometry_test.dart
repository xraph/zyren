import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

List<int> center(FrameOutput frame) => (frame as ReadbackOutput).image.pixels
    .sublist((15 * 31 + 15) * 4, (15 * 31 + 15) * 4 + 4);
void main() {
  test(
    'shared dynamic versions keep old captures and retire after the last owner',
    () async {
      final first = await NativeBackend.create(), second = first.createView();
      final geometry = PlaneGeometry(width: 2, height: 2, dynamic: true);
      final original = Float32List.fromList(geometry.positions);
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..add(Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))));
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      );
      try {
        final old = capture();
        expect(center(await first.render(old)), [255, 0, 0, 255]);
        expect((await second.render(old)).stats.uploadedBytes, 0);
        geometry.updateAttribute(
          VertexSemantic.position,
          Float32List.fromList([
            for (var i = 0; i < original.length; i++)
              original[i] + (i % 3 == 0 ? 20 : 0),
          ]),
        );
        final current = capture();
        final changed = await first.render(current);
        expect(changed.stats.uploadedBytes, 96);
        expect(center(changed), [0, 0, 0, 255]);
        expect((await first.resourceStats()).residentBytes, 368);
        expect(center(await second.render(old)), [255, 0, 0, 255]);
        // Captured data remains usable even when this view previously rendered newer data.
        expect(center(await first.render(old)), [255, 0, 0, 255]);
        expect(center(await first.render(current)), [0, 0, 0, 255]);
        expect((await second.render(current)).stats.uploadedBytes, 0);
        expect((await first.resourceStats()).residentBytes, 184);
        await first.close();
        geometry.updateAttribute(VertexSemantic.position, original);
        expect((await second.render(capture())).stats.uploadedBytes, 96);
        expect((await second.resourceStats()).residentBytes, 184);
        expect((await second.resourceStats()).liveAllocations, 1);
        scene.remove(scene.children.single);
        await second.render(capture());
        expect((await second.resourceStats()).residentBytes, 0);
      } finally {
        await first.close();
        await second.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'hidden geometry retains its base and uploads only changed UV rows',
    () async {
      final backend = await NativeBackend.create();
      final geometry = BufferGeometry(
        positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2, 0, 2, 3],
        uv0: List.filled(8, .25),
        dynamic: true,
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
        expect(center(await backend.render(capture())), [255, 0, 0, 255]);
        mesh.visible = false;
        geometry.updateAttribute(
          VertexSemantic.uv0,
          Float32List.fromList(List.filled(8, .75)),
        );
        expect((await backend.render(capture())).stats.uploadedBytes, 0);
        expect((await backend.resourceStats()).residentBytes, 192);
        mesh.visible = true;
        final shown = await backend.render(capture());
        expect(shown.stats.uploadedBytes, 64);
        expect(center(shown), [0, 255, 0, 255]);
        expect((await backend.resourceStats()).residentBytes, 192);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
