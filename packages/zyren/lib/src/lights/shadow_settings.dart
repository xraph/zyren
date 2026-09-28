part of '../scene/scene.dart';

/// Bounded directional or spot depth maps. Bias is normalized depth;
/// normalBias and maxDistance use world units. Blend materials cast no shadow.
final class ShadowSettings {
  final int resolution, cascades;
  final double near, maxDistance, bias, normalBias, splitLambda;
  ShadowSettings({
    this.resolution = 512,
    this.cascades = 1,
    this.near = .01,
    this.maxDistance = 1000,
    this.bias = .0005,
    this.normalBias = .01,
    this.splitLambda = .5,
  }) {
    if (!{128, 256, 512, 1024}.contains(resolution) ||
        cascades < 1 ||
        cascades > 4 ||
        !near.isFinite ||
        near <= 0 ||
        !maxDistance.isFinite ||
        maxDistance <= near ||
        maxDistance > 1e8 ||
        !bias.isFinite ||
        bias < 0 ||
        bias > 1 ||
        !normalBias.isFinite ||
        normalBias < 0 ||
        normalBias > 1e6 ||
        !splitLambda.isFinite ||
        splitLambda < 0 ||
        splitLambda > 1) {
      throw ArgumentError(
        'Invalid shadow resolution, range, cascade count or bias.',
      );
    }
  }
}

mixin _ShadowLight on Light {
  ShadowSettings? _shadow;
  ShadowSettings? get shadow => _shadow;
  set shadow(ShadowSettings? value) {
    if (this is SpotLight && value != null && value.cascades != 1) {
      throw ArgumentError('Spot shadows have one projection.');
    }
    _shadow = value;
    _changed();
  }
}
