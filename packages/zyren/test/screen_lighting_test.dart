import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test(
    'screen lighting is opt-in, bounded and retained in frame snapshots',
    () {
      expect(ScreenSpaceLighting().enabled, isFalse);
      expect(
        RenderSettings(screenSpaceLighting: ScreenSpaceLighting()).enabled,
        isFalse,
      );
      for (final value in [0.0, -1.0, double.nan, double.infinity]) {
        expect(() => ScreenSpaceLighting(radius: value), throwsArgumentError);
        expect(
          () => ScreenSpaceLighting(maxDistance: value),
          throwsArgumentError,
        );
        expect(
          () => ScreenSpaceLighting(thickness: value),
          throwsArgumentError,
        );
        expect(
          () => ScreenSpaceLighting(maxRoughness: value),
          throwsArgumentError,
        );
      }
      for (final value in [-1.0, 1.01, double.nan, double.infinity]) {
        expect(
          () => ScreenSpaceLighting(intensity: value),
          throwsArgumentError,
        );
        expect(() => ScreenSpaceLighting(bias: value), throwsArgumentError);
      }
      expect(() => ScreenSpaceLighting(radius: 1001), throwsArgumentError);
      expect(
        () => ScreenSpaceLighting(maxDistance: 10001),
        throwsArgumentError,
      );
      expect(() => ScreenSpaceLighting(thickness: 101), throwsArgumentError);
      expect(
        () => ScreenSpaceLighting(maxRoughness: 1.01),
        throwsArgumentError,
      );
      expect(
        [
          for (final q in ScreenSpaceQuality.values)
            ScreenSpaceLighting(quality: q).aoSamples,
        ],
        [8, 12, 16],
      );
      expect(
        [
          for (final q in ScreenSpaceQuality.values)
            ScreenSpaceLighting(quality: q).reflectionSteps,
        ],
        [16, 32, 64],
      );
      final settings = ScreenSpaceLighting(reflections: true);
      final render = RenderSettings(screenSpaceLighting: settings);
      expect(render.copyWith(exposure: 2).screenSpaceLighting, same(settings));
      expect(
        render.copyWith(clearScreenSpaceLighting: true).screenSpaceLighting,
        isNull,
      );
      final scene = Scene()..renderSettings = render;
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
      );
      scene.renderSettings = RenderSettings();
      final packet = ScenePacketEncoder(viewId: 1).encode(frame);
      expect(
        ByteData.sublistView(packet.bytes).getUint32(4, Endian.little),
        36,
      );
      expect(
        String.fromCharCodes(packet.bytes),
        contains('"screen_lighting":{"ao":false,"reflections":true'),
      );
      final probe = FrameSubmission.capture(
        scene: Scene()..renderSettings = render,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
        radianceCapture: true,
      );
      expect(probe.scene.usesScreenEffects, isFalse);
    },
  );
}
