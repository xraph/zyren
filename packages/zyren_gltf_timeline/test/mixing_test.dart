import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren/test/support/fakes.dart';
import '../../zyren_gltf/test/model_test.dart' show load;
import '../../zyren_gltf/test/support/animated_fixture.dart';

const end = Duration(seconds: 1);
Duration ms(int value) => Duration(milliseconds: value);

void main() {
  test(
    'imported actions crossfade, interrupt and release frame demand',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final scene = Scene()..add(instance);
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: modelRestClip(instance),
      );
      var demands = 0;
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      addTearDown(engine.dispose);
      Future<void> draw(Duration delta) async {
        await engine.render(
          elapsed: Duration.zero,
          time: FrameTime(delta: delta),
          width: 8,
          height: 8,
        );
      }

      await draw(Duration.zero);
      final idle = timeline.createAction(modelRestClip(instance), weight: 1);
      final moving = timeline.createAction(
        modelClip(instance, asset.animations.single),
      );
      idle.crossFadeTo(moving, end);
      await draw(Duration.zero);
      await draw(ms(500));
      expect(moving.weight, .5);
      expect(moving.position, ms(500));
      expect(instance.nodes[1]!.position.x, 1);
      expect(mesh.geometry.positions.first, 1);
      expect(timeline.position, Duration.zero);
      moving.pause();
      moving.crossFadeTo(idle, end);
      idle.pause();
      await draw(ms(500));
      expect(moving.weight, .25);
      expect(mesh.geometry.positions.first, 0);
      expect(demands, greaterThan(0));
      await draw(ms(500));
      expect(mesh.geometry.positions.first, -1);
      expect(demands, 0);
      moving.dispose();
      idle.dispose();
      expect(() => moving.play(), throwsStateError);
    },
  );

  test(
    'imported additive actions reverse and loop against a fixed reference',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: modelRestClip(instance),
      );
      final engine = await SceneEngine.create(
        scene: Scene()..add(instance),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      final action = timeline.createAction(
        modelClip(instance, asset.animations.single),
        weight: .5,
        additive: true,
        reverse: true,
        loop: true,
        referenceTime: ms(250),
      )..play();
      Future<void> draw(Duration delta) async {
        await engine.render(
          elapsed: Duration.zero,
          time: FrameTime(delta: delta),
          width: 8,
          height: 8,
        );
      }

      await draw(Duration.zero);
      await draw(ms(500));
      expect(action.position, ms(500));
      expect(mesh.geometry.positions.first, 0);
      await draw(ms(500));
      expect(action.position, end);
      expect(mesh.geometry.positions.first, 2);
      action.pause();
      action.seek(ms(250));
      expect(mesh.geometry.positions.first, -1);
      action.dispose();
    },
  );

  test(
    'authored model layers normalize overweight samples and reject foreign instances',
    () async {
      final asset = await load(animatedModel()), instance = asset.instantiate();
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final rest = modelRestClip(instance),
          clip = modelClip(instance, asset.animations.single);
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: rest,
        layers: [
          TimelineLayer(
            clip: clip,
            sampleTime: end,
            weights: [ClipWeight(Duration.zero, 1)],
          ),
          TimelineLayer(
            clip: clip,
            sampleTime: Duration.zero,
            weights: [ClipWeight(Duration.zero, 1)],
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene()..add(instance),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      timeline.seek(ms(400));
      expect(mesh.geometry.positions.first, 3);
      expect(
        () => timeline.createAction(
          modelClip(asset.instantiate(), asset.animations.single),
        ),
        throwsArgumentError,
      );
      timeline.play();
      final before = mesh.geometry.capture();
      instance.nodes[0]!.add(instance.nodes[1]!);
      expect(() => timeline.seek(end), throwsStateError);
      expect(timeline.position, ms(400));
      expect(timeline.isPlaying, isFalse);
      expect(mesh.geometry.capture(), same(before));
    },
  );
}
