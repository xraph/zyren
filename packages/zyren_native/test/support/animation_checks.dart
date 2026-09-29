import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

Future<void> verifyAnimation(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final geometry = BoxGeometry(width: .45, height: .45, depth: .45);
  final left = scene.add(Group()..position = const Vec3(-.8, -.5, 0));
  final right = scene.add(Group()..position = const Vec3(.8, -.5, 0));
  final a = left.add(
    Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))),
  );
  final b = right.add(
    Mesh(geometry, UnlitMaterial(color: const Color3(0, 0, 1))),
  );
  final clip = AnimationClip(
    tracks: [
      VectorKeyframeTrack.position(
        target: 'mesh',
        times: [0, 1],
        values: [Vec3.zero, const Vec3(0, 1, 0)],
      ),
    ],
  );
  final first = AnimationMixer(nodes: {'mesh': a}),
      second = AnimationMixer(nodes: {'mesh': b});
  final action = first.play(clip);
  second.play(clip).pause();
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
        final offset = (y * 81 + x) * 4;
        if (frame.image.pixels[offset + channel] > 200) {
          total += y;
          count++;
        }
      }
    }
    expect(count, greaterThan(30));
    return total / count;
  }

  final frozen = capture();
  final start = await render(frozen);
  action.seek(const Duration(seconds: 1));
  final moved = await render(capture());
  expect(moved.stats.drawCalls, 2);
  expect(moved.stats.uploadedBytes, 0);
  expect(centroid(moved, 0), lessThan(centroid(start, 0) - 15));
  expect(centroid(moved, 2), centroid(start, 2));
  final previous = await render(frozen);
  expect(previous.stats.uploadedBytes, 0);
  expect(centroid(previous, 0), centroid(start, 0));
  expect(b.position, Vec3.zero);
  action.stop();
  final events = <AnimationEvent>[];
  final subscription = first.events.listen(events.add);
  try {
    final finite = first.play(clip, repetitions: 2);
    first.update(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(finite.isFinished, isTrue);
    expect(events.single, isA<AnimationFinishedEvent>());
    final finished = await render(capture());
    expect(finished.image.pixels, orderedEquals(moved.image.pixels));
    expect(finished.stats.uploadedBytes, 0);
    final held = capture();
    finite.resume();
    expect(
      (await render(held)).image.pixels,
      orderedEquals(finished.image.pixels),
    );
    finite.stop();
  } finally {
    await subscription.cancel();
  }
}
