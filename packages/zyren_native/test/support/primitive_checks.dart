import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

Future<void> verifyPrimitives() async {
  final backend = await NativeBackend.create();
  final sibling = backend.createView();
  final scene = Scene()..background = const Color3(0, 0, 0);
  final camera = PerspectiveCamera();
  final geometry = LineGeometry(
    points: [const Vec3(-1, 0, 0), const Vec3(1, 0, 0)],
    dynamic: true,
  );
  final line = Line(
    geometry,
    LineMaterial(color: const Color3(1, 0, 0), width: 8),
  );
  scene.add(line);
  Future<ReadbackOutput> render({int width = 64, int height = 64}) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(width, height),
            ),
          )
          as ReadbackOutput;
  int channel(ReadbackOutput output, int x, int y, [int channel = 0]) =>
      output.image.pixels[(y * output.image.size.width + x) * 4 + channel];
  int height(ReadbackOutput output) => [
    for (var y = 0; y < output.image.size.height; y++)
      if (channel(output, output.image.size.width ~/ 2, y) > 240) y,
  ].length;
  try {
    final first = await render();
    expect(height(first), 8);
    expect(first.stats.uploadedBytes, 120);
    final oldCapture = FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(64, 64),
    );
    final shared = await sibling.render(oldCapture) as ReadbackOutput;
    expect(shared.image.pixels, first.image.pixels);
    expect(shared.stats.uploadedBytes, 0);
    expect((await backend.resourceStats()).residentBytes, 120);
    camera.position = const Vec3(0, 0, 10);
    final distant = await render();
    expect(height(distant), 8);
    expect(distant.stats.uploadedBytes, 0);
    expect(height(await render(width: 96, height: 48)), 8);
    line.material = line.material.copyWith(
      width: .5,
      widthUnits: SizeUnits.world,
    );
    final worldFar = await render();
    camera.position = const Vec3(0, 0, 5);
    final worldNear = await render();
    expect(height(worldNear), greaterThan(height(worldFar)));
    expect(worldNear.stats.uploadedBytes, 0);
    // A geometry edit rebuilds its expanded quads, preserving immutable captures.
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([-1, 1, 0, 1, 1, 0]),
    );
    expect(channel(await render(), 32, 32), 0);
    expect((await backend.resourceStats()).residentBytes, 240);
    expect(
      (await sibling.render(oldCapture) as ReadbackOutput).image.pixels,
      first.image.pixels,
    );
    await sibling.close();
    expect((await backend.resourceStats()).residentBytes, 120);
    scene.remove(line);
    final points = Points(
      PointGeometry(points: [Vec3.zero]),
      PointsMaterial(color: const Color3(1, 0, 0)),
    );
    scene.add(points);
    expect(channel(await render(), 32, 32), 255);
    points.material = points.material.copyWith(size: 16);
    final circle = await render();
    expect(channel(circle, 32, 32), 255);
    expect(channel(circle, 24, 24), 0);
    points.material = points.material.copyWith(shape: PointShape.square);
    final square = await render();
    expect(channel(square, 24, 24), 255);
    expect(square.stats.uploadedBytes, 0);
    camera.position = const Vec3(0, 0, 10);
    expect(height(await render()), 16);
    points.material = points.material.copyWith(
      size: .5,
      sizeUnits: SizeUnits.world,
    );
    final pointFar = height(await render());
    camera.position = const Vec3(0, 0, 5);
    expect(height(await render()), greaterThan(pointFar));
    points.material = points.material.copyWith(
      size: 16,
      sizeUnits: SizeUnits.pixels,
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    );
    expect(channel(await render(), 32, 32), closeTo(188, 1));
    scene.remove(points);
    final pairs = Line(
      LineGeometry.segments(
        points: [
          const Vec3(-1, -.5, 0),
          const Vec3(1, -.5, 0),
          const Vec3(-1, .5, 0),
          const Vec3(1, .5, 0),
        ],
      ),
      LineMaterial(color: const Color3(1, 0, 0), width: 4),
    );
    scene.add(pairs);
    final paired = await render();
    expect(channel(paired, 32, 32), 0);
    expect(channel(paired, 32, 25), 255);
    expect(channel(paired, 32, 39), 255);
    scene.remove(pairs);
    final degenerate = Line(
      LineGeometry(points: [Vec3.zero, Vec3.zero]),
      LineMaterial(color: const Color3(1, 0, 0), width: 64),
    );
    scene.add(degenerate);
    expect(height(await render()), 0);
    scene.remove(degenerate);
    // Clip a segment crossing the camera plane before perspective division.
    camera.position = Vec3.zero;
    camera.target = const Vec3(0, 0, -1);
    final clipped = Line(
      LineGeometry(points: [const Vec3(-.1, 0, -1), const Vec3(.2, 0, 1)]),
      LineMaterial(color: const Color3(1, 0, 0), width: 6),
    );
    scene.add(clipped);
    final crossing = await render();
    expect(
      crossing.image.pixels.where((value) => value != 0).length,
      greaterThan(4096),
    );
    clipped.position = const Vec3(0, 0, 5);
    final hidden = await render();
    expect(
      [
        for (var y = 0; y < 64; y++)
          for (var x = 0; x < 64; x++) channel(hidden, x, y),
      ].every((value) => value == 0),
      isTrue,
    );
    scene.remove(clipped);
    await render();
    expect((await backend.resourceStats()).residentBytes, 0);
  } finally {
    await sibling.close();
    await backend.close();
  }
}
