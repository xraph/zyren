import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../../gpu3d_gltf/test/support/fixtures.dart';

final class _Models implements ByteSourceResolver {
  int reads = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    return ResolvedSource(effectiveUri: uri, bytes: texturedModel());
  }
}

Future<void> verifyGltfModels() async {
  final source = _Models();
  final services = AssetServices(
    resolver: source,
    imageDecoder: const NativeImageDecoder(),
  );
  final leftAssets = AssetScope(services: services);
  final rightAssets = AssetScope(services: services);
  final backend = await NativeBackend.create();
  final sibling = backend.createView();
  try {
    final first = leftAssets.load(Gltf.asset('models/corners.glb'));
    final second = rightAssets.load(Gltf.asset('models/corners.glb'));
    final left = await first.result, right = await second.result;
    expect(source.reads, 1);
    final a = left.instantiate(), b = right.instantiate();
    Mesh mesh(Group root) => root.children.single.children.single as Mesh;
    expect(mesh(a).geometry, same(mesh(b).geometry));
    expect(
      mesh(a).material.colorMap!.image,
      same(mesh(b).material.colorMap!.image),
    );
    final scene = Scene()..add(a), otherScene = Scene()..add(b);
    final camera = PerspectiveCamera(
      position: const Vec3(0, 0, 2),
      fieldOfView: math.pi / 2,
    );
    Future<ReadbackOutput> render(NativeBackend view, Scene scene) async =>
        await view.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(63, 63),
              ),
            )
            as ReadbackOutput;
    void pixel(ReadbackOutput output, int x, int y, List<int> expected) {
      final start = (y * 63 + x) * 4;
      for (var c = 0; c < 4; c++) {
        expect(
          output.image.pixels[start + c],
          closeTo(expected[c], 1),
          reason: 'Pixel ($x, $y), channel $c',
        );
      }
    }

    void corners(ReadbackOutput output, {bool mirrored = false}) {
      pixel(output, mirrored ? 42 : 20, 20, [255, 0, 0, 255]);
      pixel(output, mirrored ? 20 : 42, 20, [0, 255, 0, 255]);
      pixel(output, mirrored ? 42 : 20, 42, [0, 0, 255, 255]);
      pixel(output, mirrored ? 20 : 42, 42, [255, 255, 255, 255]);
    }

    final initial = await render(backend, scene);
    corners(initial);
    expect(initial.stats.uploadedBytes, greaterThan(0));
    final shared = await render(sibling, otherScene);
    corners(shared);
    expect(shared.stats.uploadedBytes, 0);
    leftAssets.release(left);
    expect(left.isReleased, isTrue);
    expect(() => left.instantiate(), throwsStateError);
    a.scale = const Vec3(-1, 1, 1);
    final mirrored = await render(backend, scene);
    corners(mirrored, mirrored: true);
    expect(mirrored.stats.uploadedBytes, 0);
    // Scope release removes the template, while existing scene instances remain.
    await rightAssets.close();
    corners(await render(sibling, otherScene));
    scene.remove(a);
    await render(backend, scene);
    expect((await backend.resourceStats()).residentBytes, greaterThan(0));
    await backend.close();
    corners(await render(sibling, otherScene));
    otherScene.remove(b);
    await render(sibling, otherScene);
    expect((await sibling.resourceStats()).residentBytes, 0);
  } finally {
    await leftAssets.close();
    await rightAssets.close();
    await backend.close();
    await sibling.close();
  }
}
