import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren/test/support/fakes.dart';
import '../../zyren_gltf/test/model_test.dart' show load;
import '../../zyren_gltf/test/support/animated_fixture.dart';

void main() {
  test(
    'imported skin and morph timeline seeks silently and reverses imported events',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final scene = Scene()..add(instance);
      final timeline = modelTimeline(
        instance,
        asset.animations.single,
        reverse: true,
        loop: true,
      );
      final events = <TimelineEvent>[];
      final subscription = timeline.events.listen(events.add);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () => Future.value(TestRenderer([])),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      addTearDown(subscription.cancel);
      final mesh = instance.nodes[0]!.children.single as Mesh;
      timeline.seek(const Duration(milliseconds: 500));
      expect(mesh.geometry.positions.first, 3);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      timeline.seek(const Duration(seconds: 1));
      timeline.play();
      await engine.render(elapsed: Duration.zero, width: 8, height: 8);
      await engine.render(
        elapsed: const Duration(seconds: 1),
        time: FrameTime(delta: const Duration(seconds: 1)),
        width: 8,
        height: 8,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.marker.id), ['end', 'middle', 'start', 'end']);
      expect(timeline.position, const Duration(seconds: 1));
      expect(mesh.geometry.positions.first, 7);
    },
  );

  test(
    'instance hierarchy violations stop playback before edits or events',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final scene = Scene()..add(instance);
      final timeline = modelTimeline(instance, asset.animations.single);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () => Future.value(TestRenderer([])),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      timeline.play();
      scene.add(instance.nodes[1]!);
      expect(() => timeline.seek(const Duration(seconds: 1)), throwsStateError);
      expect(timeline.position, Duration.zero);
      expect(timeline.isPlaying, isFalse);
    },
  );
}
