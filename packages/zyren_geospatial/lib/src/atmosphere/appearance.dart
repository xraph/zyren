import 'dart:typed_data';

/// Controls composition without regenerating scattering tables. Intensities are
/// relative to the pinned WebGPU celestial model; zero hides that source.
final class AtmosphereAppearance {
  final bool sky, haze, ground;
  final bool transmittance,
      inscatter,
      sunLight,
      skyLight,
      reconstructNormal,
      correctGeometricError;
  final double albedoScale;
  final double sunIntensity,
      moonIntensity,
      starIntensity,
      starPointSize,
      moonAngularRadius;
  AtmosphereAppearance({
    this.sky = true,
    this.haze = true,
    this.ground = true,
    this.transmittance = true,
    this.inscatter = true,
    this.sunLight = false,
    this.skyLight = false,
    this.reconstructNormal = false,
    this.correctGeometricError = false,
    this.albedoScale = 1,
    this.sunIntensity = 1,
    this.moonIntensity = 1,
    this.starIntensity = 1000,
    this.starPointSize = 1,
    this.moonAngularRadius = .0045,
  }) {
    if (!albedoScale.isFinite || albedoScale < 0 || albedoScale > 65504) {
      throw ArgumentError.value(albedoScale, 'albedoScale');
    }
    for (final v in [sunIntensity, moonIntensity, starIntensity]) {
      if (!v.isFinite || v < 0 || v > 100000) {
        throw ArgumentError('Celestial intensity must be in [0, 100000].');
      }
    }
    if (!starPointSize.isFinite ||
        starPointSize < 1 ||
        starPointSize > 16 ||
        !moonAngularRadius.isFinite ||
        moonAngularRadius < 1e-5 ||
        moonAngularRadius > .099) {
      throw ArgumentError('Invalid star size or lunar angular radius.');
    }
  }
  AtmosphereAppearance copyWith({
    bool? sky,
    bool? haze,
    bool? ground,
    bool? transmittance,
    bool? inscatter,
    bool? sunLight,
    bool? skyLight,
    bool? reconstructNormal,
    bool? correctGeometricError,
    double? albedoScale,
    double? sunIntensity,
    double? moonIntensity,
    double? starIntensity,
    double? starPointSize,
    double? moonAngularRadius,
  }) => AtmosphereAppearance(
    sky: sky ?? this.sky,
    haze: haze ?? this.haze,
    ground: ground ?? this.ground,
    transmittance: transmittance ?? this.transmittance,
    inscatter: inscatter ?? this.inscatter,
    sunLight: sunLight ?? this.sunLight,
    skyLight: skyLight ?? this.skyLight,
    reconstructNormal: reconstructNormal ?? this.reconstructNormal,
    correctGeometricError: correctGeometricError ?? this.correctGeometricError,
    albedoScale: albedoScale ?? this.albedoScale,
    sunIntensity: sunIntensity ?? this.sunIntensity,
    moonIntensity: moonIntensity ?? this.moonIntensity,
    starIntensity: starIntensity ?? this.starIntensity,
    starPointSize: starPointSize ?? this.starPointSize,
    moonAngularRadius: moonAngularRadius ?? this.moonAngularRadius,
  );
}

/// An owned equirectangular sRGB RGBA8 lunar albedo map in the Moon-fixed frame.
/// With no map the plugin uses white albedo, as the upstream MoonNode does.
final class MoonMap {
  final int width, height;
  final Uint8List _bytes;
  MoonMap._(this.width, this.height, this._bytes);
  factory MoonMap({
    required int width,
    required int height,
    required Uint8List pixels,
  }) {
    if (width < 1 ||
        height < 1 ||
        width > 2048 ||
        height > 1024 ||
        pixels.length != width * height * 4) {
      throw ArgumentError('Lunar map must be RGBA8, up to 2048 by 1024.');
    }
    return MoonMap._(width, height, Uint8List.fromList(pixels));
  }
  Uint8List get pixels => Uint8List.fromList(_bytes);
}
