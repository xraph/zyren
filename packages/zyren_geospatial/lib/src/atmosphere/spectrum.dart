import 'package:zyren/zyren.dart';

/// CIE 1931 two-degree observer, using the source's 5 nm tabulation.
/// Data reference: https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer
abstract final class Cie1931 {
  static const minimumWavelength = 360.0, maximumWavelength = 830.0;

  /// Wavelength is in nanometres. The source lookup excludes both endpoints.
  static Vec3 matching(double wavelength) {
    if (!wavelength.isFinite) {
      throw ArgumentError.value(wavelength, 'wavelength');
    }
    if (wavelength <= minimumWavelength || wavelength >= maximumWavelength) {
      return Vec3.zero;
    }
    return _matching(wavelength);
  }

  static Vec3 _matching(double wavelength) {
    if (wavelength >= maximumWavelength) return _data.last;
    final u = (wavelength - minimumWavelength) / 5;
    final row = u.floor(), t = u - row;
    return _data[row] * (1 - t) + _data[row + 1] * t;
  }

  static const _data = <Vec3>[
    Vec3(0.000129900000, 0.000003917000, 0.000606100000),
    Vec3(0.000232100000, 0.000006965000, 0.001086000000),
    Vec3(0.000414900000, 0.000012390000, 0.001946000000),
    Vec3(0.000741600000, 0.000022020000, 0.003486000000),
    Vec3(0.001368000000, 0.000039000000, 0.006450001000),
    Vec3(0.002236000000, 0.000064000000, 0.010549990000),
    Vec3(0.004243000000, 0.000120000000, 0.020050010000),
    Vec3(0.007650000000, 0.000217000000, 0.036210000000),
    Vec3(0.014310000000, 0.000396000000, 0.067850010000),
    Vec3(0.023190000000, 0.000640000000, 0.110200000000),
    Vec3(0.043510000000, 0.001210000000, 0.207400000000),
    Vec3(0.077630000000, 0.002180000000, 0.371300000000),
    Vec3(0.134380000000, 0.004000000000, 0.645600000000),
    Vec3(0.214770000000, 0.007300000000, 1.039050100000),
    Vec3(0.283900000000, 0.011600000000, 1.385600000000),
    Vec3(0.328500000000, 0.016840000000, 1.622960000000),
    Vec3(0.348280000000, 0.023000000000, 1.747060000000),
    Vec3(0.348060000000, 0.029800000000, 1.782600000000),
    Vec3(0.336200000000, 0.038000000000, 1.772110000000),
    Vec3(0.318700000000, 0.048000000000, 1.744100000000),
    Vec3(0.290800000000, 0.060000000000, 1.669200000000),
    Vec3(0.251100000000, 0.073900000000, 1.528100000000),
    Vec3(0.195360000000, 0.090980000000, 1.287640000000),
    Vec3(0.142100000000, 0.112600000000, 1.041900000000),
    Vec3(0.095640000000, 0.139020000000, 0.812950100000),
    Vec3(0.057950010000, 0.169300000000, 0.616200000000),
    Vec3(0.032010000000, 0.208020000000, 0.465180000000),
    Vec3(0.014700000000, 0.258600000000, 0.353300000000),
    Vec3(0.004900000000, 0.323000000000, 0.272000000000),
    Vec3(0.002400000000, 0.407300000000, 0.212300000000),
    Vec3(0.009300000000, 0.503000000000, 0.158200000000),
    Vec3(0.029100000000, 0.608200000000, 0.111700000000),
    Vec3(0.063270000000, 0.710000000000, 0.078249990000),
    Vec3(0.109600000000, 0.793200000000, 0.057250010000),
    Vec3(0.165500000000, 0.862000000000, 0.042160000000),
    Vec3(0.225749900000, 0.914850100000, 0.029840000000),
    Vec3(0.290400000000, 0.954000000000, 0.020300000000),
    Vec3(0.359700000000, 0.980300000000, 0.013400000000),
    Vec3(0.433449900000, 0.994950100000, 0.008749999000),
    Vec3(0.512050100000, 1.000000000000, 0.005749999000),
    Vec3(0.594500000000, 0.995000000000, 0.003900000000),
    Vec3(0.678400000000, 0.978600000000, 0.002749999000),
    Vec3(0.762100000000, 0.952000000000, 0.002100000000),
    Vec3(0.842500000000, 0.915400000000, 0.001800000000),
    Vec3(0.916300000000, 0.870000000000, 0.001650001000),
    Vec3(0.978600000000, 0.816300000000, 0.001400000000),
    Vec3(1.026300000000, 0.757000000000, 0.001100000000),
    Vec3(1.056700000000, 0.694900000000, 0.001000000000),
    Vec3(1.062200000000, 0.631000000000, 0.000800000000),
    Vec3(1.045600000000, 0.566800000000, 0.000600000000),
    Vec3(1.002600000000, 0.503000000000, 0.000340000000),
    Vec3(0.938400000000, 0.441200000000, 0.000240000000),
    Vec3(0.854449900000, 0.381000000000, 0.000190000000),
    Vec3(0.751400000000, 0.321000000000, 0.000100000000),
    Vec3(0.642400000000, 0.265000000000, 0.000049999990),
    Vec3(0.541900000000, 0.217000000000, 0.000030000000),
    Vec3(0.447900000000, 0.175000000000, 0.000020000000),
    Vec3(0.360800000000, 0.138200000000, 0.000010000000),
    Vec3(0.283500000000, 0.107000000000, 0.000000000000),
    Vec3(0.218700000000, 0.081600000000, 0.000000000000),
    Vec3(0.164900000000, 0.061000000000, 0.000000000000),
    Vec3(0.121200000000, 0.044580000000, 0.000000000000),
    Vec3(0.087400000000, 0.032000000000, 0.000000000000),
    Vec3(0.063600000000, 0.023200000000, 0.000000000000),
    Vec3(0.046770000000, 0.017000000000, 0.000000000000),
    Vec3(0.032900000000, 0.011920000000, 0.000000000000),
    Vec3(0.022700000000, 0.008210000000, 0.000000000000),
    Vec3(0.015840000000, 0.005723000000, 0.000000000000),
    Vec3(0.011359160000, 0.004102000000, 0.000000000000),
    Vec3(0.008110916000, 0.002929000000, 0.000000000000),
    Vec3(0.005790346000, 0.002091000000, 0.000000000000),
    Vec3(0.004109457000, 0.001484000000, 0.000000000000),
    Vec3(0.002899327000, 0.001047000000, 0.000000000000),
    Vec3(0.002049190000, 0.000740000000, 0.000000000000),
    Vec3(0.001439971000, 0.000520000000, 0.000000000000),
    Vec3(0.000999949300, 0.000361100000, 0.000000000000),
    Vec3(0.000690078600, 0.000249200000, 0.000000000000),
    Vec3(0.000476021300, 0.000171900000, 0.000000000000),
    Vec3(0.000332301100, 0.000120000000, 0.000000000000),
    Vec3(0.000234826100, 0.000084800000, 0.000000000000),
    Vec3(0.000166150500, 0.000060000000, 0.000000000000),
    Vec3(0.000117413000, 0.000042400000, 0.000000000000),
    Vec3(0.000083075270, 0.000030000000, 0.000000000000),
    Vec3(0.000058706520, 0.000021200000, 0.000000000000),
    Vec3(0.000041509940, 0.000014990000, 0.000000000000),
    Vec3(0.000029353260, 0.000010600000, 0.000000000000),
    Vec3(0.000020673830, 0.000007465700, 0.000000000000),
    Vec3(0.000014559770, 0.000005257800, 0.000000000000),
    Vec3(0.000010253980, 0.000003702900, 0.000000000000),
    Vec3(0.000007221456, 0.000002607800, 0.000000000000),
    Vec3(0.000005085868, 0.000001836600, 0.000000000000),
    Vec3(0.000003581652, 0.000001293400, 0.000000000000),
    Vec3(0.000002522525, 0.000000910930, 0.000000000000),
    Vec3(0.000001776509, 0.000000641530, 0.000000000000),
    Vec3(0.000001251141, 0.000000451810, 0.000000000000),
  ];
}

/// Immutable, piecewise-linear spectral power per nanometre over 360-830 nm.
/// Values outside the supplied wavelength range are zero. Integrals use 683 lm/W;
/// irradiance in W/m²/nm therefore produces photometric XYZ values in lux.
final class SpectralDistribution {
  final List<double> wavelengths, values;
  SpectralDistribution({
    required Iterable<double> wavelengths,
    required Iterable<double> values,
  }) : wavelengths = _bounded(wavelengths),
       values = _bounded(values) {
    if (this.wavelengths.length < 2 ||
        this.wavelengths.length != this.values.length) {
      throw ArgumentError('A spectrum needs 2-1024 wavelength/value pairs.');
    }
    for (var i = 0; i < this.wavelengths.length; i++) {
      final wavelength = this.wavelengths[i], value = this.values[i];
      if (!wavelength.isFinite ||
          wavelength < 360 ||
          wavelength > 830 ||
          i > 0 && wavelength <= this.wavelengths[i - 1] ||
          !value.isFinite ||
          value < 0 ||
          value > 1e12) {
        throw ArgumentError(
          'Spectrum wavelengths must increase within 360-830 nm and values must be finite in 0-1e12.',
        );
      }
    }
  }
  static List<double> _bounded(Iterable<double> values) {
    final copy = values.take(1025).toList();
    if (copy.length > 1024) {
      throw ArgumentError('A spectrum supports at most 1024 samples.');
    }
    return List.unmodifiable(copy);
  }

  double sample(double wavelength) {
    if (!wavelength.isFinite) {
      throw ArgumentError.value(wavelength, 'wavelength');
    }
    if (wavelength < wavelengths.first || wavelength > wavelengths.last) {
      return 0;
    }
    if (wavelength == wavelengths.last) return values.last;
    var low = 0, high = wavelengths.length - 1;
    while (high - low > 1) {
      final mid = (low + high) ~/ 2;
      if (wavelengths[mid] <= wavelength) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final t =
        (wavelength - wavelengths[low]) /
        (wavelengths[high] - wavelengths[low]);
    return values[low] * (1 - t) + values[high] * t;
  }

  /// Exact integral of the two piecewise-linear functions on their shared knots.
  Vec3 toXyz() {
    final knots = <double>{
      ...wavelengths,
      for (var nm = 360.0; nm <= 830; nm += 5)
        if (nm > wavelengths.first && nm < wavelengths.last) nm,
    }.toList()..sort();
    var result = Vec3.zero;
    for (var i = 1; i < knots.length; i++) {
      final a = knots[i - 1], b = knots[i], s0 = sample(a), s1 = sample(b);
      // Endpoint values affect no finite-width area. Use the tabulated one-sided
      // limits here, while matching() retains the source's pointwise zeros.
      final c0 = Cie1931._matching(a), c1 = Cie1931._matching(b);
      result += (c0 * (2 * s0 + s1) + c1 * (s0 + 2 * s1)) * ((b - a) / 6);
    }
    return result * 683;
  }

  /// Linear sRGB tristimulus values. Negative out-of-gamut channels are retained.
  Vec3 toLinearSrgb() {
    final xyz = toXyz();
    return Vec3(
      3.2406255 * xyz.x - 1.537208 * xyz.y - .4986286 * xyz.z,
      -.9689307 * xyz.x + 1.8757561 * xyz.y + .0415175 * xyz.z,
      .0557101 * xyz.x - .2040211 * xyz.y + 1.0569959 * xyz.z,
    );
  }
}
