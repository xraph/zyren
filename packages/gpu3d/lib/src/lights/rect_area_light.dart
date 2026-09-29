part of '../scene/scene.dart';

/// A rectangular emitter facing local -Z. Intensity is luminance (cd/m²).
/// Width and height are metres before the world transform is applied.
final class RectAreaLight extends Light {
  double _width, _height;
  RectAreaLight({
    double width = 1,
    double height = 1,
    super.color,
    super.intensity,
    super.name,
  }) : _width = _dimension(width, 'width'),
       _height = _dimension(height, 'height');
  double get width => _width;
  set width(double value) {
    _dimension(value, 'width');
    if (_width == value) return;
    _width = value;
    _changed();
  }

  double get height => _height;
  set height(double value) {
    _dimension(value, 'height');
    if (_height == value) return;
    _height = value;
    _changed();
  }

  static double _dimension(double value, String name) {
    if (!value.isFinite || value <= 0 || value > 1e12) {
      throw ArgumentError.value(value, name, 'Expected finite (0, 1e12].');
    }
    return value;
  }

  @override
  RectAreaLight lookAt(Vec3 target) {
    super.lookAt(position * 2 - target);
    return this;
  }
}
