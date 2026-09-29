part of '../scene/scene.dart';

/// Immutable shadow quality and receiver bias. Positive depth bias moves the
/// comparison toward the light; normal bias is measured in world units.
sealed class ShadowSettings {
  final int resolution;
  final double bias, normalBias, slopeBias, filterRadius, strength;
  ShadowSettings({
    this.resolution = 512,
    this.bias = .0005,
    this.normalBias = .02,
    this.slopeBias = .002,
    this.filterRadius = 1,
    this.strength = 1,
  }) {
    if (resolution < 128 ||
        resolution > 1024 ||
        resolution & (resolution - 1) != 0) {
      throw ArgumentError.value(
        resolution,
        'resolution',
        'Use a power of two from 128 to 1024.',
      );
    }
    for (final (value, max, name) in [
      (bias, .1, 'bias'),
      (normalBias, 1e4, 'normalBias'),
      (slopeBias, .1, 'slopeBias'),
      (filterRadius, 4.0, 'filterRadius'),
      (strength, 1.0, 'strength'),
    ]) {
      if (!value.isFinite || value < 0 || value > max) {
        throw ArgumentError.value(value, name, 'Expected [0, $max].');
      }
    }
  }
}

/// Camera-fitted directional cascades. Distance is measured from the camera.
final class DirectionalShadow extends ShadowSettings {
  final int cascades;
  final double distance, splitLambda, blend;
  DirectionalShadow({
    this.cascades = 3,
    this.distance = 100,
    this.splitLambda = .5,
    this.blend = .1,
    super.resolution,
    super.bias,
    super.normalBias,
    super.slopeBias,
    super.filterRadius,
    super.strength,
  }) {
    RangeError.checkValueInInterval(cascades, 1, 4, 'cascades');
    if (!distance.isFinite ||
        distance <= 0 ||
        distance > 1e6 ||
        !splitLambda.isFinite ||
        splitLambda < 0 ||
        splitLambda > 1 ||
        !blend.isFinite ||
        blend < 0 ||
        blend > .5) {
      throw ArgumentError(
        'Invalid directional shadow distance, split or blend.',
      );
    }
  }
  DirectionalShadow copyWith({
    int? cascades,
    int? resolution,
    double? distance,
    double? splitLambda,
    double? blend,
    double? bias,
    double? normalBias,
    double? slopeBias,
    double? filterRadius,
    double? strength,
  }) => DirectionalShadow(
    cascades: cascades ?? this.cascades,
    resolution: resolution ?? this.resolution,
    distance: distance ?? this.distance,
    splitLambda: splitLambda ?? this.splitLambda,
    blend: blend ?? this.blend,
    bias: bias ?? this.bias,
    normalBias: normalBias ?? this.normalBias,
    slopeBias: slopeBias ?? this.slopeBias,
    filterRadius: filterRadius ?? this.filterRadius,
    strength: strength ?? this.strength,
  );
}

sealed class PositionalShadow extends ShadowSettings {
  final double near, far;
  PositionalShadow({
    this.near = .1,
    this.far = 100,
    super.resolution,
    super.bias,
    super.normalBias,
    super.slopeBias,
    super.filterRadius,
    super.strength,
  }) {
    if (!near.isFinite ||
        !far.isFinite ||
        near <= 0 ||
        far <= near ||
        far > 1e6) {
      throw ArgumentError(
        'Shadow clipping requires 0 < near < far <= 1000000.',
      );
    }
  }
}

final class SpotShadow extends PositionalShadow {
  SpotShadow({
    super.near,
    super.far,
    super.resolution,
    super.bias,
    super.normalBias,
    super.slopeBias,
    super.filterRadius,
    super.strength,
  });
  SpotShadow copyWith({
    double? near,
    double? far,
    int? resolution,
    double? bias,
    double? normalBias,
    double? slopeBias,
    double? filterRadius,
    double? strength,
  }) => SpotShadow(
    near: near ?? this.near,
    far: far ?? this.far,
    resolution: resolution ?? this.resolution,
    bias: bias ?? this.bias,
    normalBias: normalBias ?? this.normalBias,
    slopeBias: slopeBias ?? this.slopeBias,
    filterRadius: filterRadius ?? this.filterRadius,
    strength: strength ?? this.strength,
  );
}

/// Six faces share one light's clipping range and quality settings.
final class PointShadow extends PositionalShadow {
  PointShadow({
    super.near,
    super.far,
    super.resolution = 256,
    super.bias,
    super.normalBias,
    super.slopeBias,
    super.filterRadius,
    super.strength,
  });
  PointShadow copyWith({
    double? near,
    double? far,
    int? resolution,
    double? bias,
    double? normalBias,
    double? slopeBias,
    double? filterRadius,
    double? strength,
  }) => PointShadow(
    near: near ?? this.near,
    far: far ?? this.far,
    resolution: resolution ?? this.resolution,
    bias: bias ?? this.bias,
    normalBias: normalBias ?? this.normalBias,
    slopeBias: slopeBias ?? this.slopeBias,
    filterRadius: filterRadius ?? this.filterRadius,
    strength: strength ?? this.strength,
  );
}

/// Four rectangle patches each use six shadow views in the shared atlas.
final class AreaShadow extends PositionalShadow {
  AreaShadow({
    super.near,
    super.far,
    super.resolution = 128,
    super.bias,
    super.normalBias,
    super.slopeBias,
    super.filterRadius,
    super.strength,
  });
  AreaShadow copyWith({
    double? near,
    double? far,
    int? resolution,
    double? bias,
    double? normalBias,
    double? slopeBias,
    double? filterRadius,
    double? strength,
  }) => AreaShadow(
    near: near ?? this.near,
    far: far ?? this.far,
    resolution: resolution ?? this.resolution,
    bias: bias ?? this.bias,
    normalBias: normalBias ?? this.normalBias,
    slopeBias: slopeBias ?? this.slopeBias,
    filterRadius: filterRadius ?? this.filterRadius,
    strength: strength ?? this.strength,
  );
}
