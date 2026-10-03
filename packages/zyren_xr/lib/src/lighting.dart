import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'models.dart';

/// Maps a camera's ambient estimate onto a diffuse scene light. The host chooses
/// its neutral lux level; a camera estimate is not a measured scene irradiance.
final class XrAmbientLighting {
  final HemisphereLight light;
  final double neutralIntensityLux, neutralRelativeIntensity;
  bool available = false;

  XrAmbientLighting({
    required this.neutralIntensityLux,
    this.neutralRelativeIntensity = .5,
  }) : light = HemisphereLight(intensity: 0) {
    if (!neutralIntensityLux.isFinite ||
        neutralIntensityLux <= 0 ||
        neutralIntensityLux > 1e9 ||
        !neutralRelativeIntensity.isFinite ||
        neutralRelativeIntensity <= 0 ||
        neutralRelativeIntensity > 1) {
      throw ArgumentError(
        'Neutral lighting calibration must be finite and positive.',
      );
    }
  }

  /// Missing, stale, interrupted or invalid estimates disable this owned light.
  /// Add [light] to your scene once; no environment reflections are synthesized.
  bool update(XrSnapshot snapshot) {
    final frame = snapshot.frame, estimate = snapshot.frame?.light;
    available = false;
    light.intensity = 0;
    if (snapshot.state != XrSessionState.running ||
        frame == null ||
        frame.tracking != XrTrackingState.normal ||
        frame.ageAt(snapshot.nativeTimestamp) > .5 ||
        estimate == null ||
        !estimate.ambientIntensity.isFinite ||
        estimate.ambientIntensity < 0) {
      return false;
    }
    final double intensity;
    final Color3 color;
    if (estimate.intensityUnit == 'lumens') {
      final kelvin = estimate.colorTemperature;
      if (kelvin == null ||
          !kelvin.isFinite ||
          kelvin < 1000 ||
          kelvin > 40000) {
        return false;
      }
      intensity = neutralIntensityLux * estimate.ambientIntensity / 1000;
      color = xrBlackbodyColor(kelvin);
    } else if (estimate.intensityUnit == 'relative-gamma') {
      final correction = estimate.colorCorrection;
      if (estimate.ambientIntensity > 1 ||
          correction == null ||
          correction.any((v) => !v.isFinite || v < 0 || v > 1e6)) {
        return false;
      }
      final rgb = correction
          .take(3)
          .map((v) => math.pow(v, 2.2).toDouble())
          .toList();
      final gain = rgb.reduce(math.max);
      intensity =
          neutralIntensityLux *
          gain *
          math.pow(estimate.ambientIntensity / neutralRelativeIntensity, 2.2);
      color = gain == 0
          ? const Color3(0, 0, 0)
          : Color3(rgb[0] / gain, rgb[1] / gain, rgb[2] / gain);
    } else {
      return false;
    }
    if (!intensity.isFinite ||
        intensity > 1e12 ||
        color.toList().any((v) => !v.isFinite)) {
      return false;
    }
    light.skyColor = color;
    light.groundColor = color;
    light.intensity = intensity;
    available = true;
    return true;
  }
}

/// Approximate blackbody chromaticity, normalized into linear sRGB gamut.
/// Integrates Planck radiance using Wyman/Sloan/Shirley (JCGT 2013), equation 4.
Color3 xrBlackbodyColor(double kelvin) {
  if (!kelvin.isFinite || kelvin < 1000 || kelvin > 40000) {
    throw ArgumentError.value(kelvin, 'kelvin', 'Expected 1000 to 40000 K.');
  }
  double gaussian(double wavelength, double center, double left, double right) {
    final t = (wavelength - center) * (wavelength < center ? left : right);
    return math.exp(-.5 * t * t);
  }

  var x = 0.0, y = 0.0, z = 0.0;
  for (var wavelength = 380.0; wavelength <= 780; wavelength += 5) {
    final radiance =
        1 /
        (math.pow(wavelength, 5) *
            (math.exp(1.438776877e7 / (wavelength * kelvin)) - 1));
    x +=
        radiance *
        (1.056 * gaussian(wavelength, 599.8, .0264, .0323) +
            .362 * gaussian(wavelength, 442, .0624, .0374) -
            .065 * gaussian(wavelength, 501.1, .049, .0382));
    y +=
        radiance *
        (.821 * gaussian(wavelength, 568.8, .0213, .0247) +
            .286 * gaussian(wavelength, 530.9, .0613, .0322));
    z +=
        radiance *
        (1.217 * gaussian(wavelength, 437, .0845, .0278) +
            .681 * gaussian(wavelength, 459, .0385, .0725));
  }
  final r = math.max(0.0, 3.2406 * x - 1.5372 * y - .4986 * z);
  final g = math.max(0.0, -.9689 * x + 1.8758 * y + .0415 * z);
  final b = math.max(0.0, .0557 * x - .2040 * y + 1.0570 * z);
  final maximum = math.max(r, math.max(g, b));
  return Color3(r / maximum, g / maximum, b / maximum);
}
