import 'dart:convert';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// A clipped density function. Width and altitude are metres; scales are /metre.
final class DensityLayer {
  final double width, expTerm, expScale, linearTerm, constantTerm;
  DensityLayer({
    this.width = 0,
    this.expTerm = 0,
    this.expScale = 0,
    this.linearTerm = 0,
    this.constantTerm = 0,
  }) {
    if ([
          width,
          expTerm,
          expScale,
          linearTerm,
          constantTerm,
        ].any((x) => !x.isFinite) ||
        width < 0 ||
        width > 1000000 ||
        expTerm < 0 ||
        expTerm > 1 ||
        expScale > 0 ||
        expScale < -1 ||
        linearTerm.abs() > 1 ||
        constantTerm.abs() > 100) {
      throw ArgumentError(
        'Density layers require finite bounded coefficients and a nonpositive exponent.',
      );
    }
  }
  double density(double altitude) {
    if (!altitude.isFinite || altitude < 0) {
      throw ArgumentError.value(altitude, 'altitude');
    }
    return (expTerm * math.exp(expScale * altitude) +
            linearTerm * altitude +
            constantTerm)
        .clamp(0, 1);
  }

  List<double> get values => [
    width,
    expTerm,
    expScale,
    linearTerm,
    constantTerm,
  ];
  List<double> get shaderValues => [
    width * .001,
    expTerm,
    expScale * 1000,
    linearTerm * 1000,
    constantTerm,
  ];
}

/// Two source-compatible layers. The second extends to the atmosphere top.
final class DensityProfile {
  final DensityLayer lower, upper;
  DensityProfile(this.lower, this.upper);
  double density(double altitude) =>
      (altitude < lower.width ? lower : upper).density(altitude);
  List<double> get values => [...lower.values, ...upper.values];
}

/// Immutable three-wavelength Bruneton atmosphere. All public distances are
/// metres, scattering/extinction are /metre and angular values are radians.
final class AtmosphereParameters {
  final double bottomRadius;
  final double topRadius;
  final Vec3 solarIrradiance;
  final double sunAngularRadius;
  final Vec3 rayleighScattering;
  final Vec3 mieScattering;
  final Vec3 mieExtinction;
  final Vec3 absorptionExtinction;
  final Vec3 groundAlbedo;
  final double miePhaseFunctionG;
  final double minCosSun;
  final Vec3 sunRadianceToLuminance;
  final Vec3 skyRadianceToLuminance;
  final DensityProfile rayleighDensity;
  final DensityProfile mieDensity;
  final DensityProfile absorptionDensity;
  AtmosphereParameters({
    this.bottomRadius = 6360000,
    this.topRadius = 6420000,
    this.solarIrradiance = const Vec3(1.474, 1.8504, 1.91198),
    this.sunAngularRadius = .004675,
    this.rayleighScattering = const Vec3(.000005802, .000013558, .0000331),
    this.mieScattering = const Vec3(.000003996, .000003996, .000003996),
    this.mieExtinction = const Vec3(.00000444, .00000444, .00000444),
    this.absorptionExtinction = const Vec3(.00000065, .000001881, .000000085),
    this.groundAlbedo = const Vec3(.1, .1, .1),
    this.miePhaseFunctionG = .8,
    this.minCosSun = -.5,
    this.sunRadianceToLuminance = const Vec3(
      98242.786222,
      69954.398112,
      66475.012354,
    ),
    this.skyRadianceToLuminance = const Vec3(
      114974.916437,
      71305.954816,
      65310.548555,
    ),
    DensityProfile? rayleighDensity,
    DensityProfile? mieDensity,
    DensityProfile? absorptionDensity,
  }) : rayleighDensity =
           rayleighDensity ??
           DensityProfile(
             DensityLayer(),
             DensityLayer(expTerm: 1, expScale: -1 / 8000),
           ),
       mieDensity =
           mieDensity ??
           DensityProfile(
             DensityLayer(),
             DensityLayer(expTerm: 1, expScale: -.000833333),
           ),
       absorptionDensity =
           absorptionDensity ??
           DensityProfile(
             DensityLayer(
               width: 25000,
               linearTerm: 1 / 15000,
               constantTerm: -2 / 3,
             ),
             DensityLayer(linearTerm: -1 / 15000, constantTerm: 8 / 3),
           ) {
    bool range(double v, double lo, double hi) =>
        v.isFinite && v >= lo && v <= hi;
    bool spectrum(Vec3 v, double hi) => v.storage.every((x) => range(x, 0, hi));
    if (!range(bottomRadius, 100000, 100000000) ||
        !range(topRadius - bottomRadius, 1000, 1000000) ||
        !range((topRadius - bottomRadius) / bottomRadius, .0001, .1) ||
        !range(sunAngularRadius, .00001, .099) ||
        !range(miePhaseFunctionG, -.95, .95) ||
        !range(minCosSun, -.99, -.01) ||
        !spectrum(solarIrradiance, 100) ||
        !spectrum(groundAlbedo, 1) ||
        ![
          rayleighScattering,
          mieScattering,
          mieExtinction,
          absorptionExtinction,
        ].every((v) => spectrum(v, .001)) ||
        !spectrum(sunRadianceToLuminance, 1e7) ||
        !spectrum(skyRadianceToLuminance, 1e7) ||
        sunRadianceToLuminance.dot(const Vec3(.2126, .7152, .0722)) < 1 ||
        [
          0,
          1,
          2,
        ].any((i) => mieScattering.storage[i] > mieExtinction.storage[i])) {
      throw ArgumentError(
        'Invalid atmosphere radii, spectrum, phase or density range.',
      );
    }
  }
  factory AtmosphereParameters.legacy() => AtmosphereParameters();
  factory AtmosphereParameters.webgpu() => AtmosphereParameters(
    groundAlbedo: const Vec3(.3, .3, .3),
    mieDensity: DensityProfile(
      DensityLayer(),
      DensityLayer(expTerm: 1, expScale: -1 / 1200),
    ),
    skyRadianceToLuminance: const Vec3(
      114974.91644,
      71305.954816,
      65310.548555,
    ),
  );
  Vec3 get sunRelativeLuminance =>
      sunRadianceToLuminance /
      sunRadianceToLuminance.dot(const Vec3(.2126, .7152, .0722));
  Vec3 get skyRelativeLuminance =>
      skyRadianceToLuminance /
      sunRadianceToLuminance.dot(const Vec3(.2126, .7152, .0722));
  AtmosphereParameters copyWith({
    double? bottomRadius,
    double? topRadius,
    Vec3? solarIrradiance,
    double? sunAngularRadius,
    Vec3? rayleighScattering,
    Vec3? mieScattering,
    Vec3? mieExtinction,
    Vec3? absorptionExtinction,
    Vec3? groundAlbedo,
    double? miePhaseFunctionG,
    double? minCosSun,
    Vec3? sunRadianceToLuminance,
    Vec3? skyRadianceToLuminance,
    DensityProfile? rayleighDensity,
    DensityProfile? mieDensity,
    DensityProfile? absorptionDensity,
  }) => AtmosphereParameters(
    bottomRadius: bottomRadius ?? this.bottomRadius,
    topRadius: topRadius ?? this.topRadius,
    solarIrradiance: solarIrradiance ?? this.solarIrradiance,
    sunAngularRadius: sunAngularRadius ?? this.sunAngularRadius,
    rayleighScattering: rayleighScattering ?? this.rayleighScattering,
    mieScattering: mieScattering ?? this.mieScattering,
    mieExtinction: mieExtinction ?? this.mieExtinction,
    absorptionExtinction: absorptionExtinction ?? this.absorptionExtinction,
    groundAlbedo: groundAlbedo ?? this.groundAlbedo,
    miePhaseFunctionG: miePhaseFunctionG ?? this.miePhaseFunctionG,
    minCosSun: minCosSun ?? this.minCosSun,
    sunRadianceToLuminance:
        sunRadianceToLuminance ?? this.sunRadianceToLuminance,
    skyRadianceToLuminance:
        skyRadianceToLuminance ?? this.skyRadianceToLuminance,
    rayleighDensity: rayleighDensity ?? this.rayleighDensity,
    mieDensity: mieDensity ?? this.mieDensity,
    absorptionDensity: absorptionDensity ?? this.absorptionDensity,
  );
  String get key => jsonEncode([
    bottomRadius,
    topRadius,
    solarIrradiance.storage,
    sunAngularRadius,
    rayleighScattering.storage,
    mieScattering.storage,
    mieExtinction.storage,
    absorptionExtinction.storage,
    groundAlbedo.storage,
    miePhaseFunctionG,
    minCosSun,
    sunRadianceToLuminance.storage,
    skyRadianceToLuminance.storage,
    rayleighDensity.values,
    mieDensity.values,
    absorptionDensity.values,
  ]);
}
