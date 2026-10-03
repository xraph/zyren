import 'dart:math' as math;
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'geospatial_presets.dart';

/// Natural keeps the lunar irradiance scale. Visible also lifts unlit nights.
enum MoonlightSelection {
  off('Off', false, 1, 0),
  natural('Natural', true, 1, 0),
  visible('Visible', true, 5000, .02);

  final String label;
  final bool enabled;
  final double intensity, nightFill;
  const MoonlightSelection(
    this.label,
    this.enabled,
    this.intensity,
    this.nightFill,
  );
}

/// Keep native display detail while bounding HDR targets during replacement.
double geospatialResolutionScale({
  required double width,
  required double height,
  int maxDimension = 1920,
  int maxPixels = 2097152,
}) {
  final w = math.max(1.0, width), h = math.max(1.0, height);
  final scale = math.min(
    1.0,
    math.min(maxDimension / math.max(w, h), math.sqrt(maxPixels / (w * h))),
  );
  if ((w * scale).round() * (h * scale).round() <= maxPixels) {
    return scale;
  }
  return math.min((w * scale).floor() / w, (h * scale).floor() / h);
}

/// Shared inputs for the native Google atmosphere and cloud stories.
final class GeospatialSceneProfile extends ScenePlugin {
  late final AtmospherePlugin air;
  late final ScreenEffectsPlugin effects;
  late final CloudPlugin? cloudLayer;
  GoogleTilesPreset _preset;
  PluginContext? _context;
  CloudQualitySettings _cloudQuality;
  double _cloudDensity = 1;
  bool _cloudAnimationEnabled = true;
  MoonlightSelection _moonlight = MoonlightSelection.visible;
  bool _nightView = false;
  CloudQualitySettings get cloudQuality => _cloudQuality;
  GeospatialSceneProfile({
    required AssetServices services,
    GoogleTilesPreset? preset,
    bool clouds = false,
    PrecomputedAtmosphereSource? source,
    CloudQualitySettings? cloudQuality,
  }) : _preset =
           preset ??
           (clouds ? GoogleTilesPreset.tokyo : GoogleTilesPreset.manhattan),
       _cloudQuality =
           cloudQuality ??
           CloudQualitySettings.forDevice(CloudDeviceType.desktop) {
    air = AtmospherePlugin(
      date: date,
      source:
          source ??
          PrecomputedAtmosphereSource.upstream(
            services: services,
            format: AtmosphereLutFormat.binary,
          ),
      maxStarResolution: 2048,
      appearance: AtmosphereAppearance(
        sunLight: true,
        skyLight: true,
        moonLight: _moonlight.enabled,
        moonLightIntensity: _moonlight.intensity,
        nightLightIntensity: _moonlight.nightFill,
        reconstructNormal: true,
        correctGeometricError: true,
        albedoScale: clouds ? 2 / math.pi : .6,
      ),
    );
    effects = ScreenEffectsPlugin(
      settings: ScreenEffectsSettings(
        lens: LensFlareSettings(maxResolution: 256),
      ),
    );
    cloudLayer = clouds
        ? CloudPlugin(
            source: CloudTextureSource.upstream(services: services),
            blueNoiseSource: CloudBlueNoiseSource(services: services),
            parameters: _cloudParameters,
            animationEnabled: _cloudAnimationEnabled,
            quality: _cloudQuality.preset,
            maxResolution: _cloudQuality.maxResolution,
            maxPixels: _cloudQuality.maxPixels,
            shadowMapSize: _cloudQuality.shadowMapSize,
            shadowsEnabled: _cloudQuality.shadowsEnabled,
            shadowQuality: _cloudQuality.shadowPreset,
            shadowFarScale: .25,
          )
        : null;
  }
  CloudParameters get _cloudParameters => CloudParameters(
    coverage: _preset.coverage ?? .35,
    densityMultiplier: _cloudDensity,
    localWeatherVelocity: (.001, 0),
  );
  DateTime get date {
    final original = _preset.utcDate(year: GoogleTilesPreset.qualificationYear);
    return _nightView
        ? original.add(
            Duration(
              milliseconds: ((23 - _preset.timeOfDay) * 3600000).round(),
            ),
          )
        : original;
  }

  MoonlightSelection get moonlight => _moonlight;
  double get starIntensity => _nightView ? 50000 : 1000;
  set moonlight(MoonlightSelection value) {
    if (_moonlight == value) return;
    _moonlight = value;
    _updateMoonlight();
  }

  void _updateMoonlight() {
    if (_context == null) return;
    final controller = air.controller;
    controller.appearance = controller.appearance.copyWith(
      moonLight: _moonlight.enabled,
      moonLightIntensity: _moonlight.intensity,
      nightLightIntensity: _moonlight.nightFill,
      starIntensity: starIntensity,
    );
  }

  bool get nightView => _nightView;
  set nightView(bool value) {
    if (_nightView == value) return;
    _nightView = value;
    if (_context case final context?) {
      air.controller.date = date;
      _updateMoonlight();
      cloudLayer?.controller.resetHistory();
      context.invalidate();
    }
  }

  List<ScenePlugin> get plugins => [air, ?cloudLayer, effects, this];
  double get cloudDensity => _cloudDensity;
  set cloudDensity(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, 'cloudDensity', 'Must be in [0, 1].');
    }
    if (_cloudDensity == value) return;
    if (_context != null && cloudLayer != null) {
      cloudLayer!.controller.parameters = cloudLayer!.controller.parameters
          .copyWith(densityMultiplier: value);
    }
    _cloudDensity = value;
  }

  bool get cloudAnimationEnabled => _cloudAnimationEnabled;
  set cloudAnimationEnabled(bool value) {
    if (_cloudAnimationEnabled == value) return;
    if (_context != null && cloudLayer != null) {
      cloudLayer!.controller.animationEnabled = value;
    }
    _cloudAnimationEnabled = value;
  }

  Future<void> setCloudQuality(CloudQualitySettings settings) async {
    if (_context != null && cloudLayer != null) {
      await cloudLayer!.controller.setQualitySettings(settings);
    }
    _cloudQuality = settings;
  }

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
      if (cloudLayer case final layer?) {
        layer.controller.parameters = _cloudParameters;
        layer.controller.resetHistory();
      }
      context.invalidate();
    }
  }

  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    context.scope.onClose(() {
      _context = null;
    });
    context.service(atmosphere).date = date;
    _updateMoonlight();
    if (cloudLayer case final layer?) {
      layer.controller.parameters = _cloudParameters;
      layer.controller.animationEnabled = _cloudAnimationEnabled;
      await layer.controller.setQualitySettings(_cloudQuality);
    }
  }
}
