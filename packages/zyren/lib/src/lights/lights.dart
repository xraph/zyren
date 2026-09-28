part of '../scene/scene.dart';

sealed class Light extends Object3D {
  Color3 _color;
  double _intensity;
  Light({
    Color3 color = const Color3(1, 1, 1),
    double intensity = 1,
    super.name,
  }) : _color = color,
       _intensity = intensity {
    color.toList();
    _lightScalar(intensity, 'intensity');
  }
  Color3 get color => _color;
  set color(Color3 value) {
    value.toList();
    _color = value;
    _changed();
  }

  double get intensity => _intensity;
  set intensity(double value) {
    _lightScalar(value, 'intensity');
    _intensity = value;
    _changed();
  }
}

void _lightScalar(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1e12) {
    throw ArgumentError.value(value, name);
  }
}

/// Irradiance in lux. Direction is the local direction in which rays travel.
class DirectionalLight extends Light with _ShadowLight {
  Vec3 _direction;
  DirectionalLight({
    Vec3 direction = const Vec3(0, 0, -1),
    ShadowSettings? shadow,
    super.color,
    super.intensity,
    super.name,
  }) : _direction = direction.normalized(),
       super() {
    this.shadow = shadow;
  }
  Vec3 get direction => _direction;
  set direction(Vec3 value) {
    _direction = value.normalized();
    _changed();
  }
}

/// Luminous intensity in candela, with inverse-square falloff. Zero range is infinite.
class PointLight extends Light {
  double _range;
  PointLight({double range = 0, super.color, super.intensity, super.name})
    : _range = range {
    _lightScalar(range, 'range');
  }
  double get range => _range;
  set range(double value) {
    _lightScalar(value, 'range');
    _range = value;
    _changed();
  }
}

class SpotLight extends PointLight with _ShadowLight {
  Vec3 _direction;
  double _angle, _penumbra;
  SpotLight({
    Vec3 direction = const Vec3(0, 0, -1),
    ShadowSettings? shadow,
    double angle = math.pi / 3,
    double penumbra = 0,
    super.range,
    super.color,
    super.intensity,
    super.name,
  }) : _direction = direction.normalized(),
       _angle = angle,
       _penumbra = penumbra {
    _checkCone(angle, penumbra);
    this.shadow = shadow;
  }
  static void _checkCone(double angle, double penumbra) {
    if (!angle.isFinite ||
        angle <= 0 ||
        angle >= math.pi / 2 ||
        !penumbra.isFinite ||
        penumbra < 0 ||
        penumbra > 1) {
      throw ArgumentError('Invalid spot cone.');
    }
  }

  Vec3 get direction => _direction;
  set direction(Vec3 value) {
    _direction = value.normalized();
    _changed();
  }

  double get angle => _angle;
  set angle(double value) {
    _checkCone(value, penumbra);
    _angle = value;
    _changed();
  }

  double get penumbra => _penumbra;
  set penumbra(double value) {
    _checkCone(angle, value);
    _penumbra = value;
    _changed();
  }
}

/// Diffuse irradiance blended between ground and sky along a local up axis.
class HemisphereLight extends DirectionalLight {
  Color3 _groundColor;
  HemisphereLight({
    Color3 groundColor = const Color3(0, 0, 0),
    Vec3 up = const Vec3(0, 1, 0),
    super.color,
    super.intensity,
    super.name,
  }) : _groundColor = groundColor,
       super(direction: up) {
    groundColor.toList();
  }
  Color3 get groundColor => _groundColor;
  set groundColor(Color3 value) {
    value.toList();
    _groundColor = value;
    _changed();
  }
}
