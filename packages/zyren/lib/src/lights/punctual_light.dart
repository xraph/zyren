part of '../scene/scene.dart';

/// A scene light with linear color and a finite intensity. Each subtype defines
/// its intensity unit and orientation.
sealed class Light extends Object3D {
  Color3 _color;
  double _intensity;
  Light({
    Color3 color = const Color3(1, 1, 1),
    double intensity = 1,
    super.name,
  }) : _color = color,
       _intensity = _validateIntensity(intensity) {
    color.toList();
  }
  Color3 get color => _color;
  set color(Color3 value) {
    value.toList();
    if (value == _color) return;
    _color = value;
    _changed();
  }

  double get intensity => _intensity;
  set intensity(double value) {
    _validateIntensity(value);
    if (value == _intensity) return;
    _intensity = value;
    _changed();
  }

  static double _validateIntensity(double value) {
    if (!value.isFinite || value < 0 || value > 1e12) {
      throw ArgumentError.value(value, 'intensity', 'Expected [0, 1e12].');
    }
    return value;
  }
}

/// Directional and spot lights emit along local -Z. Directional intensity is lux;
/// point and spot intensity is candela.
sealed class PunctualLight extends Light {
  PunctualLight({super.color, super.intensity, super.name});
  ShadowSettings? get shadow;
  int _shadowRevision = 0;
  int get shadowRevision => _shadowRevision;

  /// Forces the next shadow render even when the captured scene is unchanged.
  void invalidateShadow() {
    _shadowRevision = (_shadowRevision + 1) & 0x7fffffff;
    _changed();
  }

  /// Points the emitting -Z axis at a target in parent coordinates.
  @override
  PunctualLight lookAt(Vec3 target) {
    super.lookAt(position * 2 - target);
    return this;
  }
}

final class DirectionalLight extends PunctualLight {
  DirectionalShadow? _shadow;
  @override
  DirectionalShadow? get shadow => _shadow;
  set shadow(DirectionalShadow? value) {
    if (identical(value, _shadow)) return;
    _shadow = value;
    _changed();
  }

  DirectionalLight({
    DirectionalShadow? shadow,
    super.color,
    super.intensity,
    super.name,
  }) : _shadow = shadow;
}

sealed class PositionalLight extends PunctualLight {
  double? _range;
  PositionalLight({double? range, super.color, super.intensity, super.name})
    : _range = _validateRange(range);

  /// Metres; null gives inverse-square falloff without a finite cutoff.
  double? get range => _range;
  set range(double? value) {
    _validateRange(value);
    if (value == _range) return;
    _range = value;
    _changed();
  }

  static double? _validateRange(double? value) {
    if (value != null && (!value.isFinite || value <= 0 || value > 1e12)) {
      throw ArgumentError.value(value, 'range', 'Expected (0, 1e12] or null.');
    }
    return value;
  }
}

final class PointLight extends PositionalLight {
  PointShadow? _shadow;
  @override
  PointShadow? get shadow => _shadow;
  set shadow(PointShadow? value) {
    if (identical(value, _shadow)) return;
    _shadow = value;
    _changed();
  }

  PointLight({
    PointShadow? shadow,
    super.color,
    super.intensity,
    super.range,
    super.name,
  }) : _shadow = shadow;
}

final class SpotLight extends PositionalLight {
  SpotShadow? _shadow;
  @override
  SpotShadow? get shadow => _shadow;
  set shadow(SpotShadow? value) {
    if (identical(value, _shadow)) return;
    _shadow = value;
    _changed();
  }

  double _inner, _outer;
  SpotLight({
    SpotShadow? shadow,
    double innerConeAngle = 0,
    double outerConeAngle = math.pi / 4,
    super.color,
    super.intensity,
    super.range,
    super.name,
  }) : _shadow = shadow,
       _inner = innerConeAngle,
       _outer = outerConeAngle {
    _validateCone(_inner, _outer);
  }
  double get innerConeAngle => _inner;
  double get outerConeAngle => _outer;
  void setCone({
    required double innerConeAngle,
    required double outerConeAngle,
  }) {
    _validateCone(innerConeAngle, outerConeAngle);
    if (_inner == innerConeAngle && _outer == outerConeAngle) return;
    _inner = innerConeAngle;
    _outer = outerConeAngle;
    _changed();
  }

  static void _validateCone(double inner, double outer) {
    if (!inner.isFinite ||
        !outer.isFinite ||
        inner < 0 ||
        inner >= outer ||
        outer > math.pi / 2) {
      throw ArgumentError('Cone angles require 0 <= inner < outer <= pi/2.');
    }
  }
}
