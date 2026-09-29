import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';

void main() {
  test(
    'HDR histories isolate shared scenes and restart on a replacement device',
    () async {
      final device = await NativeBackend.create();
      final scene = Scene()..background = const Color3(1, 0, 0);
      final aEffects = PostProcessing(
        bloom: BloomOptions(intensity: 0),
        antialias: true,
      );
      final bEffects = PostProcessing(bloom: BloomOptions(intensity: 0));
      final aHistory = TemporalBlendPlugin(
        enabled: true,
        retention: .5,
        after: {aEffects.id},
      );
      final bHistory = TemporalBlendPlugin(
        enabled: true,
        retention: .5,
        after: {bEffects.id},
      );
      Future<SceneEngine> attach(
        NativeBackend device,
        PostProcessing effects,
        TemporalBlendPlugin history,
      ) => SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => device.createView(),
        plugins: [effects, history],
        onIssue: (issue) => fail(issue.toString()),
      );
      Future<ReadbackOutput> draw(
        SceneEngine engine, {
        int width = 17,
        double exposure = .5,
      }) async =>
          await engine.renderFrame(
                elapsed: Duration.zero,
                width: width,
                height: 13,
                colorPipeline: ColorPipeline(
                  sampleCount: 4,
                  toneMapping: ToneMapping.linear,
                  exposure: exposure,
                ),
              )
              as ReadbackOutput;
      void pixel(ReadbackOutput frame, List<int> expected) {
        for (var i = 0; i < 4; i++) {
          expect(frame.image.pixels[i], closeTo(expected[i], 2));
        }
      }

      final a = await attach(device, aEffects, aHistory);
      final b = await attach(device, bEffects, bHistory);
      NativeBackend? replacement;
      SceneEngine? recovered;
      try {
        pixel(await draw(a), [188, 0, 0, 255]);
        scene.background = const Color3(0, 1, 0);
        pixel(await draw(a), [137, 137, 0, 255]);
        pixel(await draw(b), [0, 188, 0, 255]);
        expect(aHistory.historyFrames, 2);
        expect(bHistory.historyFrames, 1);
        pixel(await draw(a, exposure: 1), [137, 225, 0, 255]);
        expect(aHistory.historyFrames, 3);
        scene.background = const Color3(0, 0, 1);
        (a.camera as PerspectiveCamera).fieldOfView = .7;
        pixel(await draw(a), [0, 0, 188, 255]);
        expect(aHistory.historyFrames, 1);
        scene.background = const Color3(1, 0, 0);
        aHistory.reset();
        pixel(await draw(a), [188, 0, 0, 255]);
        scene.background = const Color3(0, 0, 1);
        pixel(await draw(a, width: 23), [0, 0, 188, 255]);
        pixel(await draw(b), [0, 137, 137, 255]);
        expect(bHistory.historyFrames, 2);
        await a.dispose();
        expect(aHistory.historyFrames, 0);
        pixel(await draw(b), [0, 99, 165, 255]);
        await b.dispose();
        expect((await device.resourceStats()).residentBytes, 0);
        expect((await device.graphStats()).liveGraphs, 0);
        await device.close();

        // Recovery reattaches the same plugin instances to a fresh native device.
        replacement = await NativeBackend.create();
        recovered = await attach(replacement, aEffects, aHistory);
        scene.background = const Color3(0, 1, 0);
        pixel(await draw(recovered), [0, 188, 0, 255]);
        expect(aHistory.historyFrames, 1);
        await recovered.dispose();
        expect((await replacement.resourceStats()).residentBytes, 0);
        expect((await replacement.shaderStats()).livePrograms, 0);
      } finally {
        await a.dispose();
        await b.dispose();
        await recovered?.dispose();
        await device.close();
        await replacement?.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
