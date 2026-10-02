import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'geospatial_presets.dart';

/// Shared inputs for the native Google atmosphere and cloud stories.
final class GeospatialSceneProfile extends ScenePlugin {
  late final AtmospherePlugin air;
  late final ScreenEffectsPlugin effects;
  late final CloudPlugin? cloudLayer;
  GoogleTilesPreset _preset;
  PluginContext? _context;
  GeospatialSceneProfile({
    required AssetServices services,
    GoogleTilesPreset preset = GoogleTilesPreset.manhattan,
    bool clouds = false,
    PrecomputedAtmosphereSource? source,
  }) : _preset = preset {
    air = AtmospherePlugin(
      date: date,
      source:
          source ??
          PrecomputedAtmosphereSource.upstream(
            services: services,
            format: AtmosphereLutFormat.binary,
          ),
      maxStarResolution: 256,
      appearance: AtmosphereAppearance(
        sunLight: true,
        skyLight: true,
        reconstructNormal: true,
        correctGeometricError: true,
        albedoScale: .6,
      ),
    );
    effects = ScreenEffectsPlugin(
      settings: ScreenEffectsSettings(
        lens: LensFlareSettings(maxResolution: 256),
      ),
    );
    cloudLayer = clouds
        ? CloudPlugin(maxResolution: 192, shadowMapSize: 128)
        : null;
  }
  DateTime get date =>
      _preset.utcDate(year: GoogleTilesPreset.qualificationYear);
  List<ScenePlugin> get plugins => [air, ?cloudLayer, effects, this];
  @override
  String get id => 'geospatial-scene';
  @override
  Set<String> get dependencies => {
    'atmosphere',
    if (cloudLayer != null) 'clouds',
  };
  void apply(Scene scene, Camera camera, GoogleTilesPreset preset) {
    _preset = preset;
    preset.applyCamera(camera);
    scene.renderSettings = scene.renderSettings.copyWith(
      hdr: true,
      exposure: preset.exposure,
      toneMapping: ToneMapping.agx,
      spatialAntialiasing: SpatialAntialiasing.none,
    );
    if (_context case final context?) {
      context.service(atmosphere).date = date;
      cloudLayer?.controller.resetHistory();
      context.invalidate();
    }
  }

  @override
  void attach(PluginContext context) {
    _context = context;
    context.service(atmosphere).date = date;
    context.scope.onClose(() {
      _context = null;
    });
  }
}
