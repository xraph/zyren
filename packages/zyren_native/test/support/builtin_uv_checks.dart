import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

Future<void> verifyBuiltinUvs() async {
  final backend = await NativeBackend.create();
  final scene = Scene();
  final camera = PerspectiveCamera(
    position: const Vec3(0, 0, 3),
    fieldOfView: math.pi / 2,
  );
  const colors = [
    [255, 0, 0, 255],
    [0, 255, 0, 255],
    [0, 0, 255, 255],
    [255, 255, 255, 255],
  ];
  final corners = TextureImage.rgba(
    width: 2,
    height: 2,
    pixels: Uint8List.fromList(colors.expand((v) => v).toList()),
  );
  const nearest = SamplerDescriptor(
    minFilter: TextureFilter.nearest,
    magFilter: TextureFilter.nearest,
  );
  final box = scene.add(
    Mesh(
      BoxGeometry(width: 2, height: 2, depth: 2),
      UnlitMaterial(
        colorMap: TextureMap(image: corners, sampler: nearest),
      ),
    ),
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
    final poses = [
      (const Vec3(0, 0, 3), const Vec3(0, 1, 0)),
      (const Vec3(0, 0, -3), const Vec3(0, 1, 0)),
      (const Vec3(3, 0, 0), const Vec3(0, 1, 0)),
      (const Vec3(-3, 0, 0), const Vec3(0, 1, 0)),
      (const Vec3(0, 3, 0), const Vec3(0, 0, -1)),
      (const Vec3(0, -3, 0), const Vec3(0, 0, 1)),
    ];
    for (var face = 0; face < poses.length; face++) {
      camera.position = poses[face].$1;
      camera.up = poses[face].$2;
      final frame = await render();
      for (var i = 0; i < 4; i++) {
        expect(
          pixel(frame, i.isEven ? 20 : 44, i < 2 ? 20 : 44),
          colors[i],
          reason: 'face $face corner $i',
        );
      }
      expect(frame.stats.uploadedBytes, face == 0 ? 1120 : 0);
    }
    scene.remove(box);
    const south = [
      [0, 255, 255, 255],
      [255, 0, 255, 255],
      [255, 255, 0, 255],
      [0, 0, 0, 255],
    ];
    final map = TextureImage.rgba(
      width: 4,
      height: 2,
      pixels: Uint8List.fromList(
        [...colors, ...south].expand((v) => v).toList(),
      ),
    );
    final sphere = scene.add(
      Mesh(
        SphereGeometry(widthSegments: 48, heightSegments: 24),
        UnlitMaterial(
          colorMap: TextureMap(image: map, sampler: nearest),
        ),
      ),
    );
    camera.up = const Vec3(0, 1, 0);
    for (var quadrant = 0; quadrant < 4; quadrant++) {
      final angle = (quadrant + .5) * math.pi / 2;
      camera.position = Vec3(3 * math.cos(angle), 0, 3 * math.sin(angle));
      final frame = await render();
      expect(
        pixel(frame, 32, 24),
        colors[quadrant],
        reason: 'north quadrant $quadrant',
      );
      expect(
        pixel(frame, 32, 40),
        south[quadrant],
        reason: 'south quadrant $quadrant',
      );
      if (quadrant > 0) expect(frame.stats.uploadedBytes, 0);
    }
    scene.remove(sphere);
    await render();
    expect((await backend.resourceStats()).residentBytes, 0);
  } finally {
    await backend.close();
  }
}
