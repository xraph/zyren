import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test(
    'builtin effects have bounded immutable settings and packet support',
    () {
      for (final value in [-1.0, double.nan, double.infinity]) {
        expect(() => BloomSettings(intensity: value), throwsArgumentError);
        expect(() => BloomSettings(threshold: value), throwsArgumentError);
        expect(() => BloomSettings(softKnee: value), throwsArgumentError);
        expect(() => BloomSettings(scatter: value), throwsArgumentError);
      }
      expect(() => BloomSettings(softKnee: 1.1), throwsArgumentError);
      expect(() => BloomSettings(scatter: 1.1), throwsArgumentError);
      expect(() => BloomSettings(levels: 0), throwsArgumentError);
      expect(() => BloomSettings(levels: 7), throwsArgumentError);
      final bloom = BloomSettings(intensity: .5, levels: 3);
      final settings = RenderSettings(
        spatialAntialiasing: SpatialAntialiasing.fxaa,
        bloom: bloom,
      );
      expect(settings.enabled, isTrue);
      final copied = settings.copyWith(exposure: 2);
      expect(copied.bloom, same(bloom));
      expect(copied.spatialAntialiasing, SpatialAntialiasing.fxaa);
      expect(settings.copyWith(clearBloom: true).bloom, isNull);
      final scene = Scene()..renderSettings = settings;
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
      );
      scene.renderSettings = RenderSettings();
      final packet = ScenePacketEncoder(viewId: 1).encode(frame);
      expect(
        ByteData.sublistView(packet.bytes).getUint32(4, Endian.little),
        27,
      );
    },
  );
}
