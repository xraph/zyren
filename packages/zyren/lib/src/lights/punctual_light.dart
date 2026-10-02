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
  Vec3 _direction;
  PunctualLight({
    Vec3 direction = const Vec3(0, 0, -1),
    super.color,
    super.intensity,
    super.name,
  }) : _direction = direction.normalized();
  Vec3 get direction => _direction;
  set direction(Vec3 value) {
    _direction = value.normalized();
    _changed();
  }

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
    direction = const Vec3(0, 0, -1);
    super.lookAt(position * 2 - target);
    return this;
  }
}

final class DirectionalLight extends PunctualLight {
  DirectionalShadow? _shadow;
  @override
  DirectionalShadow? get shadow => _shadow;
  set shadow(ShadowSettings? settings) {
    final value = _directionalShadow(settings);
    if (identical(value, _shadow)) return;
    _shadow = value;
    _changed();
  }

  DirectionalLight({
    ShadowSettings? shadow,
    super.direction,
    super.color,
    super.intensity,
    super.name,
  }) : _shadow = _directionalShadow(shadow);
}

sealed class PositionalLight extends PunctualLight {
  double? _range;
  PositionalLight({
    double? range,
    super.direction,
    super.color,
    super.intensity,
    super.name,
  }) : _range = _validateRange(range);

  /// Metres; null gives inverse-square falloff without a finite cutoff.
  double? get range => _range;
  set range(double? value) {
    value = _validateRange(value);
    if (value == _range) return;
    _range = value;
    _changed();
  }

  static double? _validateRange(double? value) {
    if (value == 0) return null;
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
  set shadow(ShadowSettings? settings) {
    final value = _spotShadow(settings);
    if (value != null && _outer >= math.pi / 2) {
      throw ArgumentError('Spot shadows need an angle below pi/2.');
    }
    if (identical(value, _shadow)) return;
    _shadow = value;
    _changed();
  }

  double _inner, _outer;
  SpotLight({
    ShadowSettings? shadow,
    super.direction,
    double? angle,
    double? penumbra,
    double innerConeAngle = 0,
    double outerConeAngle = math.pi / 4,
    super.color,
    super.intensity,
    super.range,
    super.name,
  }) : _shadow = _spotShadow(shadow),
       _inner = penumbra == null
           ? innerConeAngle
           : (angle ?? outerConeAngle) * (1 - penumbra),
       _outer = angle ?? outerConeAngle {
    if (penumbra != null &&
        (!penumbra.isFinite || penumbra < 0 || penumbra > 1)) {
      throw ArgumentError.value(penumbra, 'penumbra');
    }
    if (_shadow != null && _outer >= math.pi / 2) {
      throw ArgumentError('Spot shadows need an angle below pi/2.');
    }
    _validateCone(_inner, _outer);
  }
  double get angle => _outer;
  set angle(double value) =>
      setCone(innerConeAngle: value * (1 - penumbra), outerConeAngle: value);
  double get penumbra => 1 - _inner / _outer;
  set penumbra(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, 'penumbra');
    }
    setCone(innerConeAngle: _outer * (1 - value), outerConeAngle: _outer);
  }

  double get innerConeAngle => _inner;
  double get outerConeAngle => _outer;
  void setCone({
    required double innerConeAngle,
    required double outerConeAngle,
  }) {
    _validateCone(innerConeAngle, outerConeAngle);
    if (_shadow != null && outerConeAngle >= math.pi / 2) {
      throw ArgumentError('Spot shadows need an angle below pi/2.');
    }
    if (_inner == innerConeAngle && _outer == outerConeAngle) return;
    _inner = innerConeAngle;
    _outer = outerConeAngle;
    _changed();
  }

  static void _validateCone(double inner, double outer) {
    if (!inner.isFinite ||
        !outer.isFinite ||
        inner < 0 ||
        inner > outer ||
        outer > math.pi / 2) {
      throw ArgumentError('Cone angles require 0 <= inner < outer <= pi/2.');
    }
  }
}
