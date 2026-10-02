import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren_gltf/test/model_test.dart' show load;
import '../../zyren_gltf/test/support/animated_fixture.dart';

List<int> center(FrameOutput output) => (output as ReadbackOutput).image.pixels
    .sublist((15 * 31 + 15) * 4, (15 * 31 + 15) * 4 + 4);

void main() {
  test(
    'native imported animation uploads deformed geometry and restores a seek',
    () async {
      final asset = await load(animatedModel(bindPosition: 2)),
          instance = asset.instantiate();
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..add(instance);
      final timeline = modelTimeline(instance, asset.animations.single);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: NativeBackend.create,
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      if (Platform.isMacOS) {
        expect(engine.capabilities.backend?.toLowerCase(), 'metal');
      }
      Future<FrameOutput> draw() =>
          engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
      timeline.seek(Duration.zero);
      expect(center(await draw()), [255, 0, 0, 255]);
      timeline.seek(const Duration(seconds: 1));
      final moved = await draw();
      expect(center(moved), [0, 0, 0, 255]);
      expect(moved.stats.uploadedBytes, greaterThan(0));
      timeline.seek(Duration.zero);
      expect(center(await draw()), [255, 0, 0, 255]);
      final unchanged = await draw();
      expect(unchanged.stats.uploadedBytes, 0);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'native runtime crossfades, additive layers and reverse loops update pixels',
    () async {
      final scene = Scene()..background = const Color3(0, 0, 0);
      final mesh = scene.add(
        Mesh(
          PlaneGeometry(width: 2, height: 2),
          UnlitMaterial(color: const Color3(1, 0, 0)),
        ),
      );
      const length = Duration(seconds: 1);
      TimelineClip clip(double x) => TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero, position: Vec3(x, 0, 0)),
          ]),
        ],
      );
      final timeline = SceneTimelinePlugin.mixed(
        duration: length,
        base: clip(0),
        reverse: true,
        loop: true,
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: NativeBackend.create,
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      Future<FrameOutput> draw(Duration delta) => engine.renderFrame(
        elapsed: Duration.zero,
        time: FrameTime(delta: delta),
        width: 31,
        height: 31,
      );
      final idle = timeline.createAction(clip(0), weight: 1)..play();
      final shifted = timeline.createAction(clip(4));
      timeline.play();
      idle.crossFadeTo(shifted, length);
      expect(center(await draw(Duration.zero)), [255, 0, 0, 255]);
      expect(center(await draw(length)), [0, 0, 0, 255]);
      shifted.fadeTo(0, Duration.zero);
      idle.fadeTo(1, Duration.zero);
      final additive = timeline.createAction(
        TimelineClip(
          duration: length,
          tracks: [
            TransformTrack(mesh, [
              TransformKeyframe(Duration.zero),
              TransformKeyframe(length, position: const Vec3(4, 0, 0)),
            ]),
          ],
        ),
        additive: true,
        weight: 1,
        reverse: true,
        loop: true,
      )..play();
      expect(center(await draw(Duration.zero)), [0, 0, 0, 255]);
      additive.seek(Duration.zero);
      expect(center(await draw(Duration.zero)), [
        0,
        0,
        0,
        255,
      ]); // exact reverse loop boundary samples the end
      additive.pause();
      additive.seek(Duration.zero);
      expect(center(await draw(Duration.zero)), [255, 0, 0, 255]);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test('native authored layers retain reverse loop boundary samples', () async {
    final scene = Scene()..background = const Color3(0, 0, 0);
    final mesh = scene.add(
      Mesh(
        PlaneGeometry(width: 2, height: 2),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      ),
    );
    const length = Duration(seconds: 1);
    final base = TimelineClip(
      duration: length,
      tracks: [
        TransformTrack(mesh, [TransformKeyframe(Duration.zero)]),
      ],
    );
    final moving = TimelineClip(
      duration: length,
      tracks: [
        TransformTrack(mesh, [
          TransformKeyframe(Duration.zero),
          TransformKeyframe(length, position: const Vec3(4, 0, 0)),
        ]),
      ],
    );
    final timeline = SceneTimelinePlugin.mixed(
      duration: const Duration(seconds: 2),
      base: base,
      layers: [
        TimelineLayer(
          clip: moving,
          loop: true,
          reverse: true,
          weights: [ClipWeight(Duration.zero, 1)],
        ),
      ],
    );
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      backendFactory: NativeBackend.create,
      plugins: [timeline],
    );
    addTearDown(engine.dispose);
    Future<FrameOutput> draw() =>
        engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
    timeline.seek(const Duration(milliseconds: 999));
    expect(center(await draw()), [255, 0, 0, 255]);
    timeline.seek(length);
    expect(center(await draw()), [0, 0, 0, 255]);
    timeline.seek(const Duration(milliseconds: 1999));
    expect(center(await draw()), [255, 0, 0, 255]);
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
