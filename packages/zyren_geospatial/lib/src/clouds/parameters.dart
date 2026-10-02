import 'dart:math' as math;
import 'package:zyren/zyren.dart';

void _range(double value, double low, double high, String name) {
  if (!value.isFinite || value < low || value > high) {
    throw ArgumentError.value(value, name, 'Expected $low through $high.');
  }
}

/// Source exponential/linear cloud profile, evaluated at normalized layer height.
final class CloudDensityProfile {
  final double expTerm, exponent, linearTerm, constantTerm;
  CloudDensityProfile({
    this.expTerm = 0,
    this.exponent = 0,
    this.linearTerm = 0,
    this.constantTerm = 0,
  }) {
    for (final value in [expTerm, linearTerm, constantTerm]) {
      _range(value, -100, 100, 'density coefficient');
    }
    _range(exponent, -80, 80, 'density exponent');
  }
  double sample(double heightFraction) {
    _range(heightFraction, 0, 1, 'heightFraction');
    return expTerm * math.exp(exponent * heightFraction) +
        linearTerm * heightFraction +
        constantTerm;
  }

  Map<String, double> toJson() => {
    'expTerm': expTerm,
    'exponent': exponent,
    'linearTerm': linearTerm,
    'constantTerm': constantTerm,
  };
}

/// One weather channel and its altitude interval in metres. Zero height disables it.
final class CloudLayer {
  final int channel;
  final double altitude,
      height,
      densityScale,
      shapeAmount,
      shapeDetailAmount,
      weatherExponent,
      shapeAlteringBias,
      coverageFilterWidth;
  final bool shadow;
  final CloudDensityProfile densityProfile;
  CloudLayer({
    this.channel = 0,
    this.altitude = 0,
    this.height = 0,
    this.densityScale = .2,
    this.shapeAmount = 1,
    this.shapeDetailAmount = 1,
    this.weatherExponent = 1,
    this.shapeAlteringBias = .35,
    this.coverageFilterWidth = .6,
    this.shadow = false,
    CloudDensityProfile? densityProfile,
  }) : densityProfile =
           densityProfile ??
           CloudDensityProfile(linearTerm: .75, constantTerm: .25) {
    RangeError.checkValueInInterval(channel, 0, 3, 'channel');
    _range(altitude, 0, 100000, 'altitude');
    _range(height, 0, 100000 - altitude, 'height');
    _range(densityScale, 0, 100, 'densityScale');
    for (final value in [shapeAmount, shapeDetailAmount, shapeAlteringBias]) {
      _range(value, 0, 1, 'shape amount');
    }
    _range(weatherExponent, 0, 32, 'weatherExponent');
    _range(coverageFilterWidth, 1e-6, 1, 'coverageFilterWidth');
  }
  factory CloudLayer.fromJson(Map<String, dynamic> value) {
    double n(String key, double fallback) =>
        (value[key] as num?)?.toDouble() ?? fallback;
    final p = value['densityProfile'] as Map?;
    return CloudLayer(
      channel: value.containsKey('channel')
          ? 'rgba'.indexOf(value['channel'] as String)
          : 0,
      altitude: n('altitude', 0),
      height: n('height', 0),
      densityScale: n('densityScale', .2),
      shapeAmount: n('shapeAmount', 1),
      shapeDetailAmount: n('shapeDetailAmount', 1),
      weatherExponent: n('weatherExponent', 1),
      shapeAlteringBias: n('shapeAlteringBias', .35),
      coverageFilterWidth: n('coverageFilterWidth', .6),
      shadow: value['shadow'] as bool? ?? false,
      densityProfile: p == null
          ? null
          : CloudDensityProfile(
              expTerm: (p['expTerm'] as num?)?.toDouble() ?? 0,
              exponent: (p['exponent'] as num?)?.toDouble() ?? 0,
              linearTerm: (p['linearTerm'] as num?)?.toDouble() ?? .75,
              constantTerm: (p['constantTerm'] as num?)?.toDouble() ?? .25,
            ),
    );
  }
  Map<String, Object> toJson() => {
    'channel': 'rgba'[channel],
    'altitude': altitude,
    'height': height,
    'densityScale': densityScale,
    'shapeAmount': shapeAmount,
    'shapeDetailAmount': shapeDetailAmount,
    'weatherExponent': weatherExponent,
    'shapeAlteringBias': shapeAlteringBias,
    'coverageFilterWidth': coverageFilterWidth,
    'shadow': shadow,
    'densityProfile': densityProfile.toJson(),
  };
}

/// Four immutable source-compatible layers and their three empty altitude gaps.
final class CloudLayers {
  final List<CloudLayer> layers;
  CloudLayers([Iterable<CloudLayer> layers = const []])
    : layers = _copy(layers);
  static List<CloudLayer> _copy(Iterable<CloudLayer> layers) {
    final values = layers.take(5).toList();
    if (values.length > 4) {
      throw ArgumentError('At most four cloud layers are supported.');
    }
    while (values.length < 4) {
      values.add(CloudLayer());
    }
    return List.unmodifiable(values);
  }

  factory CloudLayers.defaults() => CloudLayers([
    CloudLayer(channel: 0, altitude: 750, height: 650, shadow: true),
    CloudLayer(channel: 1, altitude: 1000, height: 1200, shadow: true),
    CloudLayer(
      channel: 2,
      altitude: 7500,
      height: 500,
      densityScale: .003,
      shapeAmount: .4,
      shapeDetailAmount: 0,
      coverageFilterWidth: .5,
    ),
    CloudLayer(channel: 3),
  ]);
  List<(double, double)> get gaps {
    final events =
        [
          for (final layer in layers) ...[
            (layer.altitude, 0),
            (layer.altitude + layer.height, 1),
          ],
        ]..sort(
          (a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
        );
    final result = <(double, double)>[];
    var balance = 0;
    for (var i = 0; i < events.length; i++) {
      if (balance == 0 && i > 0) result.add((events[i - 1].$1, events[i].$1));
      balance += events[i].$2 == 0 ? 1 : -1;
    }
    while (result.length < 3) {
      result.add((0, 0));
    }
    return List.unmodifiable(result);
  }

  double get minimumAltitude => _edge(false, false);
  double get maximumAltitude => _edge(true, false);
  double get shadowBottom => _edge(false, true);
  double get shadowTop => _edge(true, true);
  double _edge(bool top, bool shadows) {
    final active = layers.where((v) => v.height > 0 && (!shadows || v.shadow));
    if (active.isEmpty) return 0;
    return active
        .map((v) => v.altitude + (top ? v.height : 0))
        .reduce(top ? math.max : math.min);
  }
}

/// Immutable source weather, motion and participating-medium controls.
/// Repeats are per metre for volumes and per globe UV for weather/turbulence.
final class CloudParameters {
  final CloudLayers layers;
  final double coverage,
      scatteringCoefficient,
      absorptionCoefficient,
      turbulenceDisplacement;
  final (double, double) localWeatherRepeat,
      localWeatherOffset,
      localWeatherVelocity,
      turbulenceRepeat;
  final Vec3 shapeRepeat,
      shapeOffset,
      shapeVelocity,
      shapeDetailRepeat,
      shapeDetailOffset,
      shapeDetailVelocity;
  CloudParameters({
    CloudLayers? layers,
    this.coverage = .3,
    this.scatteringCoefficient = 1,
    this.absorptionCoefficient = 0,
    this.turbulenceDisplacement = 350,
    this.localWeatherRepeat = (100, 100),
    this.localWeatherOffset = (0, 0),
    this.localWeatherVelocity = (0, 0),
    this.turbulenceRepeat = (20, 20),
    this.shapeRepeat = const Vec3(.0003, .0003, .0003),
    this.shapeOffset = Vec3.zero,
    this.shapeVelocity = Vec3.zero,
    this.shapeDetailRepeat = const Vec3(.006, .006, .006),
    this.shapeDetailOffset = Vec3.zero,
    this.shapeDetailVelocity = Vec3.zero,
  }) : layers = layers ?? CloudLayers.defaults() {
    _range(coverage, 0, 1, 'coverage');
    _range(scatteringCoefficient, 0, 100, 'scatteringCoefficient');
    _range(absorptionCoefficient, 0, 100, 'absorptionCoefficient');
    _range(turbulenceDisplacement, 0, 100000, 'turbulenceDisplacement');
    for (final value in [
      localWeatherRepeat.$1,
      localWeatherRepeat.$2,
      turbulenceRepeat.$1,
      turbulenceRepeat.$2,
      ...shapeRepeat.storage,
      ...shapeDetailRepeat.storage,
    ]) {
      _range(value, 1e-9, 1e6, 'repeat');
    }
    for (final value in [
      localWeatherOffset.$1,
      localWeatherOffset.$2,
      localWeatherVelocity.$1,
      localWeatherVelocity.$2,
      ...shapeOffset.storage,
      ...shapeVelocity.storage,
      ...shapeDetailOffset.storage,
      ...shapeDetailVelocity.storage,
    ]) {
      _range(value, -1e6, 1e6, 'offset or velocity');
    }
  }
}
