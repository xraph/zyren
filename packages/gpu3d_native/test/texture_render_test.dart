import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test('native texture corners, UV sets, wrap and color conversion', () async {
    final backend = await NativeBackend.create();
    final image = TextureImage.rgba(
      width: 2,
      height: 2,
      pixels: Uint8List.fromList([
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
      ]),
    );
    final geometry = BufferGeometry(
      positions: [-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2, 0, 2, 3],
      uv0: [1, 2, 2, 2, 2, 1, 1, 1],
      uv1: [.75, .75, .75, .75, .75, .75, .75, .75],
    );
    const repeat = SamplerDescriptor(
      wrapU: TextureWrap.repeat,
      wrapV: TextureWrap.repeat,
      minFilter: TextureFilter.nearest,
      magFilter: TextureFilter.nearest,
    );
    final mesh = Mesh(
      geometry,
      UnlitMaterial(
        colorMap: TextureMap(image: image, sampler: repeat),
      ),
    );
    final scene = Scene()..add(mesh);
    final camera = PerspectiveCamera(
      position: const Vec3(0, 0, 2),
      fieldOfView: math.pi / 2,
    );
    Future<ReadbackOutput> render() async =>
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(64, 64),
              ),
            )
            as ReadbackOutput;
    List<int> pixel(ReadbackOutput frame, int x, int y) =>
        frame.image.pixels.sublist((y * 64 + x) * 4, (y * 64 + x) * 4 + 4);
    try {
      expect(
        backend.capabilities.supports(RenderFeature.colorTextures),
        isTrue,
      );
      final corners = await render();
      expect(pixel(corners, 16, 16), [255, 0, 0, 255]);
      expect(pixel(corners, 48, 16), [0, 255, 0, 255]);
      expect(pixel(corners, 16, 48), [0, 0, 255, 255]);
      expect(pixel(corners, 48, 48), [255, 255, 255, 255]);
      expect(corners.stats.uploadedBytes, 200);
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(
          image: image,
          sampler: const SamplerDescriptor(
            wrapU: TextureWrap.repeat,
            wrapV: TextureWrap.repeat,
          ),
        ),
      );
      for (final channel in pixel(await render(), 32, 32).take(3)) {
        expect(channel, closeTo(188, 4));
      }
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(
          image: image,
          sampler: const SamplerDescriptor(
            wrapU: TextureWrap.mirroredRepeat,
            wrapV: TextureWrap.mirroredRepeat,
            minFilter: TextureFilter.nearest,
            magFilter: TextureFilter.nearest,
          ),
        ),
      );
      final mirrored = await render();
      expect(pixel(mirrored, 16, 16), [255, 255, 255, 255]);
      expect(pixel(mirrored, 48, 16), [0, 0, 255, 255]);
      expect(pixel(mirrored, 16, 48), [0, 255, 0, 255]);
      expect(pixel(mirrored, 48, 48), [255, 0, 0, 255]);
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(image: image, uvSet: 1, sampler: repeat),
      );
      final secondUv = await render();
      expect(pixel(secondUv, 16, 16), [255, 255, 255, 255]);
      expect(secondUv.stats.uploadedBytes, 0);
      mesh.material = UnlitMaterial(
        colorMap: TextureMap(
          image: image,
          sampler: const SamplerDescriptor(
            minFilter: TextureFilter.nearest,
            magFilter: TextureFilter.nearest,
          ),
        ),
      );
      expect(pixel(await render(), 16, 16), [255, 255, 255, 255]);
      for (final format in TextureFormat.values) {
        final gray = TextureImage.rgba(
          width: 1,
          height: 1,
          format: format,
          pixels: Uint8List.fromList([128, 128, 128, 0]),
        );
        mesh.material = UnlitMaterial(colorMap: TextureMap(image: gray));
        final expected = format == TextureFormat.rgba8UnormSrgb ? 128 : 188;
        final grayPixel = pixel(await render(), 32, 32);
        expect(grayPixel[0], closeTo(expected, 1));
        expect(grayPixel[3], 255);
      }
      final box = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0))),
      );
      expect(pixel(await render(), 32, 32), [255, 0, 0, 255]);
      scene.remove(mesh);
      scene.add(mesh);
      expect(pixel(await render(), 32, 32), [255, 0, 0, 255]);
      scene.remove(box);
      scene.remove(mesh);
      await render();
      expect((await backend.resourceStats()).residentBytes, 0);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  test('shared textures survive hiding and sample a supplied mip', () async {
    final first = await NativeBackend.create();
    final second = first.createView();
    final image = TextureImage.rgba(
      width: 2,
      height: 2,
      pixels: Uint8List.fromList(
        List.generate(16, (i) => i % 4 == 0 || i % 4 == 3 ? 255 : 0),
      ),
      mipmaps: [
        Uint8List.fromList([0, 0, 255, 255]),
      ],
    );
    final geometry = BufferGeometry(
      positions: [-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2, 0, 2, 3],
      uv0: [0, 64, 64, 64, 64, 0, 0, 0],
    );
    final mesh = Mesh(
      geometry,
      UnlitMaterial(
        colorMap: TextureMap(
          image: image,
          sampler: const SamplerDescriptor(
            wrapU: TextureWrap.repeat,
            wrapV: TextureWrap.repeat,
            minFilter: TextureFilter.nearest,
            magFilter: TextureFilter.nearest,
            mipFilter: TextureFilter.nearest,
          ),
        ),
      ),
    );
    final scene = Scene()..add(mesh);
    FrameSubmission frame() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(0, 0, 2),
        fieldOfView: math.pi / 2,
      ),
      size: PhysicalSize(64, 64),
    );
    try {
      final frames = await Future.wait([
        first.render(frame()),
        second.render(frame()),
      ]);
      expect(frames.fold(0, (sum, f) => sum + f.stats.uploadedBytes), 204);
      expect((await first.resourceStats()).residentBytes, 204);
      mesh.visible = false;
      await second.render(frame());
      await first.close();
      expect((await second.resourceStats()).residentBytes, 204);
      mesh.visible = true;
      final restored = await second.render(frame()) as ReadbackOutput;
      expect(restored.stats.uploadedBytes, 0);
      final center = (32 * 64 + 32) * 4;
      expect(restored.image.pixels.sublist(center, center + 4), [
        0,
        0,
        255,
        255,
      ]);
      scene.remove(mesh);
      await second.render(frame());
      expect((await second.resourceStats()).residentBytes, 0);
    } finally {
      await first.close();
      await second.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
