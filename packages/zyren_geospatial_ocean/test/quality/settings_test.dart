import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('quality presets retain the approved work limits and round trip', () {
    final expected = [
      [64, 2, 96, 65536, .5, 0, 0, 0, 32],
      [128, 3, 192, 131072, .5, 16, 12, 2048, 64],
      [256, 4, 384, 262144, .75, 32, 24, 8192, 128],
      [512, 4, 768, 524288, 1.0, 64, 48, 32768, 256],
    ];
    for (final profile in OceanRenderQuality.values) {
      final settings = profile.settings;
      expect([
        settings.fftResolution,
        settings.maxBands,
        settings.maxPatches,
        settings.maxVertices,
        settings.sceneInputScale,
        settings.ssrSteps,
        settings.shaftSteps,
        settings.sprayParticleCap,
        settings.gpuBudgetBytes ~/ 1048576,
      ], expected[profile.index]);
      expect(
        OceanQualitySettings.fromJson(settings.toJson()).toJson(),
        settings.toJson(),
      );
      expect(settings.preset, profile);
      expect(settings.lod.maxPatches, settings.maxPatches);
      expect(settings.lod.maxVertices, settings.maxVertices);
      expect(settings.reflections.effectiveSteps(640, 480), settings.ssrSteps);
      expect(settings.underwater.shaftSteps, settings.shaftSteps);
      expect(settings.underwater.causticResolution, settings.causticResolution);
      expect(
        settings.applyTo(RenderSettings(exposure: 2)).opaqueCaptureScale,
        settings.sceneInputScale,
      );
      expect(settings.applyTo(RenderSettings(exposure: 2)).exposure, 2);
      expect(settings.copyWith(fftResolution: 4).preset, isNull);
    }
  });
  test('custom settings reject invalid or unknown serialized work limits', () {
    final base = OceanRenderQuality.low.settings;
    for (final invalid in [0, 3, 12, 1024]) {
      expect(() => base.copyWith(fftResolution: invalid), throwsArgumentError);
    }
    expect(() => base.copyWith(sceneInputScale: .1), throwsArgumentError);
    expect(() => base.copyWith(sprayParticleCap: -1), throwsArgumentError);
    expect(() => base.copyWith(ssrSteps: 65), throwsArgumentError);
    expect(
      () => OceanQualitySettings.fromJson({
        ...base.toJson(),
        'fftResolution': 64.5,
      }),
      throwsFormatException,
    );
    expect(
      () => OceanQualitySettings.fromJson({
        ...base.toJson(),
        'decorativeQuality': 'ultra',
      }),
      throwsFormatException,
    );
    expect(
      () => OceanQualitySettings.fromJson({...base.toJson(), 'version': 2}),
      throwsFormatException,
    );
  });
}
