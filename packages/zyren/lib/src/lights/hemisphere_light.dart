part of '../scene/scene.dart';

/// Diffuse indirect irradiance, in lux, interpolated between sky and ground.
/// Local +Y points toward the sky. This light does not supply specular reflections.
final class HemisphereLight extends Light {
  Color3 _groundColor;
  HemisphereLight({
    Color3 skyColor = const Color3(1, 1, 1),
    Color3 groundColor = const Color3(0, 0, 0),
    super.intensity,
    super.name,
  }) : _groundColor = groundColor,
       super(color: skyColor) {
    groundColor.toList();
  }
  Color3 get skyColor => color;
  set skyColor(Color3 value) => color = value;
  Color3 get groundColor => _groundColor;
  set groundColor(Color3 value) {
    value.toList();
    if (value == _groundColor) return;
    _groundColor = value;
    _changed();
  }
}
