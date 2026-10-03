import 'draw_cache_accounting.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

Future<void> verifyGeneratedSceneMips() async {
  final first = await NativeBackend.create();
  final second = first.createView();
  final image = TextureImage.rgba(
    width: 2,
    height: 2,
    generateMipmaps: true,
    pixels: Uint8List.fromList([
      0,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      0,
      0,
      0,
      255,
    ]),
  );
  final mesh = Mesh(
    BufferGeometry(
      positions: [-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2, 0, 2, 3],
      uv0: [0, 64, 64, 64, 64, 0, 0, 0],
    ),
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
    expect(frames.fold(0, (sum, f) => sum + f.stats.uploadedBytes), 200);
    expect((await sceneAssetPayloadBytes(first)), 204);
    mesh.visible = false;
    await second.render(frame());
    await first.close();
    expect((await sceneAssetPayloadBytes(second)), 204);
    mesh.visible = true;
    final restored = await second.render(frame()) as ReadbackOutput;
    expect(restored.stats.uploadedBytes, 0);
    final center = (32 * 64 + 32) * 4;
    for (final c in restored.image.pixels.sublist(center, center + 3)) {
      expect(c, closeTo(188, 1));
    }
    scene.remove(mesh);
    await second.render(frame());
    expect((await second.resourceStats()).residentBytes, 0);
  } finally {
    await first.close();
    await second.close();
  }
}

Future<void> verifyResourceMips() async {
  final backend = await NativeBackend.create();
  final scope = backend.createResourceScope();
  Future<List<int>> mip(
    int width,
    int height,
    List<int> pixels, {
    TextureFormat format = TextureFormat.rgba8Unorm,
    MipmapAlphaFilter alpha = MipmapAlphaFilter.independent,
    int? level,
  }) async {
    final resource = await scope.createTexture(
      TextureDescriptor(
        width: width,
        height: height,
        format: format,
        mipLevels: (width > height ? width : height).bitLength,
        usage: {
          TextureUsage.sampled,
          TextureUsage.renderAttachment,
          TextureUsage.copySource,
          TextureUsage.copyDestination,
        },
      ),
    );
    await scope.writeTexture(resource, Uint8List.fromList(pixels));
    final uploaded = (await backend.resourceStats()).uploadedBytes;
    await scope.generateMipmaps(resource, alphaFilter: alpha);
    expect((await backend.resourceStats()).uploadedBytes, uploaded);
    return scope.readTexture(
      resource,
      mipLevel:
          level ?? (resource.descriptor as TextureDescriptor).mipLevels - 1,
    );
  }

  try {
    final bw = [
      0,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      0,
      0,
      0,
      255,
    ];
    expect(await mip(2, 2, bw), [128, 128, 128, 255]);
    final srgb = await mip(2, 2, bw, format: TextureFormat.rgba8UnormSrgb);
    for (final c in srgb.take(3)) {
      expect(c, closeTo(188, 1));
    }
    expect(srgb[3], 255);
    final edges = [255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0, 255, 0, 0, 255];
    expect(await mip(2, 2, edges, alpha: MipmapAlphaFilter.weighted), [
      255,
      0,
      0,
      128,
    ]);
    expect(await mip(2, 2, edges), [128, 0, 128, 128]);
    expect(
      await mip(
        2,
        2,
        List.generate(16, (i) => i % 4 == 3 ? 0 : 255),
        alpha: MipmapAlphaFilter.weighted,
      ),
      [0, 0, 0, 0],
    );
    final odd = [
      for (var i = 0; i < 15; i++) ...[i == 14 ? 255 : 0, 0, 0, 255],
    ];
    expect(await mip(5, 3, odd, level: 1), [0, 0, 0, 255, 34, 0, 0, 255]);
    expect(await mip(5, 3, odd), [17, 0, 0, 255]);
    expect(await mip(1, 3, [0, 0, 0, 255, 0, 0, 0, 255, 255, 0, 0, 255]), [
      85,
      0,
      0,
      255,
    ]);
    expect(await mip(1, 1, [10, 20, 30, 255]), [10, 20, 30, 255]);
    final reusable = await scope.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        mipLevels: 2,
        format: TextureFormat.rgba8Unorm,
        usage: {
          TextureUsage.sampled,
          TextureUsage.renderAttachment,
          TextureUsage.copySource,
          TextureUsage.copyDestination,
        },
      ),
    );
    final sharedScope = backend.createResourceScope();
    try {
      final shared = await sharedScope.retain(reusable);
      for (final color in [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
      ]) {
        await scope.writeTexture(
          reusable,
          Uint8List.fromList([for (var i = 0; i < 4; i++) ...color]),
        );
        await scope.generateMipmaps(reusable);
        expect(await sharedScope.readTexture(shared, mipLevel: 1), color);
      }
    } finally {
      await sharedScope.close();
    }
    final invalid = await scope.createTexture(
      TextureDescriptor(width: 2, height: 2, mipLevels: 2),
    );
    await expectLater(
      scope.generateMipmaps(invalid),
      throwsA(isA<ArgumentError>()),
    );
  } finally {
    await scope.close();
    await backend.close();
  }
}
