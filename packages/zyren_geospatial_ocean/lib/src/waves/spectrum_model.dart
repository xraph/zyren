import 'dart:math' as math;
import 'sea_state.dart';

/// A deterministic, stateless density model. IDs and versions identify all model
/// behaviour; register a new version when its constants or equations change.
abstract interface class OceanSpectrumModel {
  String get id;
  int get version;
  double energy(
    double kx,
    double kz,
    OceanWaveBand band, {
    double gravity = 9.81,
  });
}

/// Directional Phillips density with short-wave damping at 0.001 of the wind
/// length and 0.07 counter-wind energy. Density is integrated over dkx * dkz.
final class PhillipsSpectrum implements OceanSpectrumModel {
  const PhillipsSpectrum();
  @override
  String get id => 'phillips';
  @override
  int get version => 1;
  @override
  double energy(
    double kx,
    double kz,
    OceanWaveBand band, {
    double gravity = 9.81,
  }) {
    if (!kx.isFinite || !kz.isFinite || !gravity.isFinite || gravity <= 0) {
      throw ArgumentError('Spectrum coordinates and gravity must be finite.');
    }
    final k2 = kx * kx + kz * kz;
    if (k2 == 0 || band.windSpeed == 0 || band.amplitude == 0) return 0;
    final k = math.sqrt(k2), length = band.windSpeed * band.windSpeed / gravity;
    final alignment =
        (kx * math.cos(band.windHeadingRadians) +
            kz * math.sin(band.windHeadingRadians)) /
        k;
    return band.amplitude *
        math.exp(-1 / (k2 * length * length) - k2 * length * length * .000001) /
        (k2 * k2) *
        alignment *
        alignment *
        (alignment < 0 ? .07 : 1);
  }
}

final class OceanSpectrumRegistry {
  final Map<(String, int), OceanSpectrumModel> _models = {};
  OceanSpectrumRegistry({
    Iterable<OceanSpectrumModel> models = const [PhillipsSpectrum()],
  }) {
    for (final model in models.take(65)) {
      if (_models.length >= 64 ||
          !RegExp(r'^[a-z][a-z0-9._-]{0,63}$').hasMatch(model.id) ||
          model.version < 1 ||
          model.version > 65535 ||
          _models.containsKey((model.id, model.version))) {
        throw ArgumentError(
          'Spectrum registrations require unique bounded IDs and versions.',
        );
      }
      _models[(model.id, model.version)] = model;
    }
  }
  OceanSpectrumModel require(String id, int version) =>
      _models[(id, version)] ??
      (throw ArgumentError(
        'The saved spectrum model is not registered: $id v$version.',
      ));
}
