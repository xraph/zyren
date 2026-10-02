import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:zyren_effects/zyren_effects.dart';

void main() {
  test(
    'combined presets configure source atmosphere and bounded native effects',
    () {
      final profile = GeospatialSceneProfile(
        services: const SceneRuntime().assetServices,
      );
      final scene = Scene(), camera = PerspectiveCamera();
      for (final preset in GoogleTilesPreset.values) {
        profile.apply(scene, camera, preset);
        expect(scene.renderSettings.toneMapping, ToneMapping.agx);
        expect(scene.renderSettings.exposure, preset.exposure);
        expect(
          scene.renderSettings.spatialAntialiasing,
          SpatialAntialiasing.none,
        );
        expect(profile.date, preset.utcDate(year: 2026));
        expect(
          camera.position.distanceTo(camera.target),
          closeTo(preset.distance, 1e-6),
        );
      }
      expect(profile.air.source, isNotNull);
      expect(profile.air.source!.combinedScattering, isTrue);
      expect(profile.air.source!.higherOrderScattering, isTrue);
      expect(profile.air.appearance.sunLight, isTrue);
      expect(profile.air.appearance.skyLight, isTrue);
      expect(profile.air.appearance.albedoScale, .6);
      expect(profile.air.appearance.correctGeometricError, isTrue);
      expect(profile.effects.settings.lens!.intensity, .005);
      expect(profile.effects.settings.smaa, SmaaPreset.medium);
      expect(profile.effects.settings.dithering, isTrue);
      expect(profile.plugins.map((p) => p.id), [
        'atmosphere',
        'screen-effects',
        'geospatial-scene',
      ]);
      final cloudProfile = GeospatialSceneProfile(
        services: const SceneRuntime().assetServices,
        clouds: true,
      );
      expect(cloudProfile.cloudLayer!.maxResolution, 192);
      expect(cloudProfile.cloudLayer!.shadowMapSize, 128);
      expect(cloudProfile.plugins.map((p) => p.id), contains('clouds'));
    },
  );
}
