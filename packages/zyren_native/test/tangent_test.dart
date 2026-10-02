import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'explicit tangent handedness survives mirrored transforms and shared dynamic edits',
    () async {
      final backend = await NativeBackend.create(),
          other = backend.createView();
      final plane = PlaneGeometry(width: 2, height: 2);
      Float32List tangents(double sign) => Float32List.fromList([
        for (var i = 0; i < 4; i++) ...[1.0, 0.0, 0.0, sign],
      ]);
      final geometry = BufferGeometry.fromAttributes(
        attributes: {
          ...plane.attributes,
          VertexSemantic.tangent: VertexAttribute(
            tangents(1),
            format: VertexFormat.float32x4,
          ),
        },
        indices: plane.indices,
        dynamic: true,
      );
      final normal = TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          format: TextureFormat.rgba8Unorm,
          pixels: Uint8List.fromList([128, 255, 128, 255]),
        ),
      );
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final mesh = scene.add(
        Mesh(geometry, StandardMaterial(normalMap: normal)),
      );
      scene.add(DirectionalLight(direction: const Vec3(0, -1, 0)));
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: 0,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(33, 33),
      );
      Future<int> red(NativeBackend view, FrameSubmission frame) async {
        final result = await view.render(frame) as ReadbackOutput;
        return result.image.pixels[(16 * 33 + 16) * 4];
      }

      try {
        final saved = capture();
        ScenePacketEncoder(viewId: 999).encode(saved);
        final bright = await red(backend, saved);
        expect(bright, greaterThan(50));
        expect(await red(other, saved), bright);
        mesh.scale = const Vec3(-1, 1, 1);
        expect(await red(backend, capture()), closeTo(bright, 1));
        mesh.scale = Vec3.one;
        final before = await backend.resourceStats();
        geometry.updateAttribute(VertexSemantic.tangent, tangents(-1));
        expect(await red(backend, capture()), lessThan(5));
        final after = await backend.resourceStats();
        expect(after.uploadedBytes - before.uploadedBytes, 64);
        expect(await red(other, saved), bright);
        expect(await red(other, capture()), lessThan(5));
        scene.remove(mesh);
        await red(backend, capture());
        await red(other, capture());
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
        await other.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
