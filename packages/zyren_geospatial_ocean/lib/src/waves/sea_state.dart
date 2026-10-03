import 'dart:convert';
import 'dart:math' as math;
import 'spectrum_model.dart';

final class OceanWaveBand {
  final double patchMetres,
      minWaveNumber,
      maxWaveNumber,
      windSpeed,
      windHeadingRadians,
      amplitude,
      choppiness;
  final double? depthMetres;
  OceanWaveBand({
    required this.patchMetres,
    required this.minWaveNumber,
    required this.maxWaveNumber,
    required this.windSpeed,
    required this.windHeadingRadians,
    this.amplitude = 1,
    this.choppiness = 1,
    this.depthMetres,
  }) {
    if (![
          patchMetres,
          minWaveNumber,
          maxWaveNumber,
          windSpeed,
          windHeadingRadians,
          amplitude,
          choppiness,
          ?depthMetres,
        ].every((v) => v.isFinite) ||
        patchMetres < .01 ||
        patchMetres > 1e7 ||
        minWaveNumber < 0 ||
        maxWaveNumber <= minWaveNumber ||
        maxWaveNumber > 1e5 ||
        windSpeed < 0 ||
        windSpeed > 200 ||
        windHeadingRadians.abs() > math.pi * 2 ||
        amplitude < 0 ||
        amplitude > 1e4 ||
        choppiness < 0 ||
        choppiness > 10 ||
        (depthMetres != null && (depthMetres! <= 0 || depthMetres! > 1e7))) {
      throw ArgumentError('Invalid finite ocean wave band.');
    }
  }
  double window(double k) {
    if (k <= minWaveNumber || k >= maxWaveNumber) return 0;
    final v = math.sin(
      math.pi * (k - minWaveNumber) / (maxWaveNumber - minWaveNumber),
    );
    return v * v;
  }

  Map<String, Object?> toJson() => {
    'patchMetres': patchMetres,
    'minWaveNumber': minWaveNumber,
    'maxWaveNumber': maxWaveNumber,
    'windSpeed': windSpeed,
    'windHeadingRadians': windHeadingRadians,
    'amplitude': amplitude,
    'choppiness': choppiness,
    'depthMetres': depthMetres,
  };
  factory OceanWaveBand.fromJson(Map<String, Object?> json) => OceanWaveBand(
    patchMetres: (json['patchMetres'] as num).toDouble(),
    minWaveNumber: (json['minWaveNumber'] as num).toDouble(),
    maxWaveNumber: (json['maxWaveNumber'] as num).toDouble(),
    windSpeed: (json['windSpeed'] as num).toDouble(),
    windHeadingRadians: (json['windHeadingRadians'] as num).toDouble(),
    amplitude: (json['amplitude'] as num).toDouble(),
    choppiness: (json['choppiness'] as num).toDouble(),
    depthMetres: (json['depthMetres'] as num?)?.toDouble(),
  );
}

/// Immutable physical state, independent of cameras and visual resolution.
final class OceanSeaState {
  static const formatVersion = 1;
  final int seed, canonicalResolution;
  final List<OceanWaveBand> bands;
  final double gravity, density, meanLevel;
  final OceanSpectrumModel spectrum;
  late final String revision = 'ocean-v1-${_fingerprint(jsonEncode(toJson()))}';
  OceanSeaState({
    required this.seed,
    required this.canonicalResolution,
    required List<OceanWaveBand> bands,
    this.gravity = 9.81,
    this.density = 1025,
    this.meanLevel = 0,
    this.spectrum = const PhillipsSpectrum(),
  }) : bands = List.unmodifiable(bands.take(9)) {
    if (seed < 0 ||
        seed > 0xffffffff ||
        canonicalResolution < 4 ||
        canonicalResolution > 512 ||
        (canonicalResolution & (canonicalResolution - 1)) != 0 ||
        this.bands.isEmpty ||
        this.bands.length > 8 ||
        !gravity.isFinite ||
        gravity <= 0 ||
        gravity > 1e4 ||
        !density.isFinite ||
        density <= 0 ||
        density > 1e5 ||
        !meanLevel.isFinite ||
        meanLevel.abs() > 1e7) {
      throw ArgumentError(
        'Ocean state needs bounded physical values and a power-of-two grid from 4 to 512.',
      );
    }
    OceanSpectrumRegistry(models: [spectrum]);
  }

  /// Raised-sine windows divide shared frequency energy without exceeding one.
  double energyWeight(int bandIndex, double waveNumber) {
    RangeError.checkValidIndex(bandIndex, bands);
    if (!waveNumber.isFinite || waveNumber < 0) {
      throw ArgumentError('Invalid wave number.');
    }
    final sum = bands.fold(0.0, (v, b) => v + b.window(waveNumber));
    return bands[bandIndex].window(waveNumber) / math.max(1, sum);
  }

  Map<String, Object?> toJson() => {
    'format': formatVersion,
    'seed': seed,
    'canonicalResolution': canonicalResolution,
    'gravity': gravity,
    'density': density,
    'meanLevel': meanLevel,
    'spectrum': {'id': spectrum.id, 'version': spectrum.version},
    'bands': bands.map((b) => b.toJson()).toList(),
  };
  factory OceanSeaState.fromJson(
    Map<String, Object?> json, {
    OceanSpectrumRegistry? registry,
  }) {
    try {
      if (json['format'] != formatVersion || jsonEncode(json).length > 16384) {
        throw ArgumentError('Unsupported sea state document.');
      }
      final model = json['spectrum'] as Map;
      final bands = json['bands'] as List;
      if (bands.isEmpty || bands.length > 8) {
        throw ArgumentError('Invalid saved bands.');
      }
      return OceanSeaState(
        seed: json['seed'] as int,
        canonicalResolution: json['canonicalResolution'] as int,
        gravity: (json['gravity'] as num).toDouble(),
        density: (json['density'] as num).toDouble(),
        meanLevel: (json['meanLevel'] as num).toDouble(),
        spectrum: (registry ?? OceanSpectrumRegistry()).require(
          model['id'] as String,
          model['version'] as int,
        ),
        bands: bands
            .map(
              (b) => OceanWaveBand.fromJson((b as Map).cast<String, Object?>()),
            )
            .toList(),
      );
    } on ArgumentError {
      rethrow;
    } catch (_) {
      throw ArgumentError('Malformed sea state document.');
    }
  }
}

// FNV-1a 64 identifies descriptors, not security-sensitive resource content.
String _fingerprint(String text) {
  var h = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16),
      mask = (BigInt.one << 64) - BigInt.one;
  for (final byte in utf8.encode(text)) {
    h = ((h ^ BigInt.from(byte)) * prime) & mask;
  }
  return h.toRadixString(16).padLeft(16, '0');
}
