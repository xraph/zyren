import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../../gpu3d_gltf/test/support/animation_fixture.dart';

final class _AnimatedSource implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: animatedModel());
}

Future<void> verifyGltfAnimation(NativeGpuBackend backend) async {
  final assets = AssetScope(
    services: AssetServices(resolver: _AnimatedSource()),
  );
  try {
    final model = await assets.load(Gltf.asset('animated.glb')).result;
    final left = model.instantiate()..position = const Vec3(-.8, -.5, 0);
    final right = model.instantiate()..position = const Vec3(.8, -.5, 0);
    for (final instance in [left, right]) {
      instance.nodes[1]!.scale = const Vec3(.3, .3, .3);
    }
    (right.nodes[1]!.children.single as Mesh).material = UnlitMaterial(
      color: const Color3(0, 0, 1),
    );
    final action = left.mixer.play(left.animations.single)..pause();
    right.mixer.play(right.animations.single).pause();
    final scene = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(left)
      ..add(right);
    final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(81, 81),
    );
    Future<ReadbackOutput> render(FrameSubmission frame) async =>
        await backend.render(frame) as ReadbackOutput;
    double centroid(ReadbackOutput frame, int channel) {
      var total = 0, count = 0;
      for (var y = 0; y < 81; y++) {
        for (var x = 0; x < 81; x++) {
          if (frame.image.pixels[(y * 81 + x) * 4 + channel] > 200) {
            total += y;
            count++;
          }
        }
      }
      expect(count, greaterThan(30));
      return total / count;
    }

    final frozen = capture(), start = await render(capture());
    assets.release(model);
    action.seek(const Duration(seconds: 2));
    final moved = await render(capture());
    expect(moved.stats.drawCalls, 2);
    expect(moved.stats.uploadedBytes, 0);
    expect(centroid(moved, 0), lessThan(centroid(start, 0) - 15));
    expect(centroid(moved, 2), centroid(start, 2));
    final previous = await render(frozen);
    expect(centroid(previous, 0), centroid(start, 0));
    expect(right.nodes[0]!.position, Vec3.zero);
  } finally {
    await assets.close();
  }
}
