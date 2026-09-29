part of 'scene.dart';

/// A centered orthographic view. Horizontal size follows the viewport aspect.
class OrthographicCamera extends Camera {
  Vec3 _target, _up;
  double _verticalSize, _zoom, _near, _far;
  OrthographicCamera({
    Vec3 position = const Vec3(0, 0, 5),
    Vec3 target = Vec3.zero,
    Vec3 up = const Vec3(0, 1, 0),
    double verticalSize = 4,
    double zoom = 1,
    double near = .1,
    double far = 1000,
  }) : _target = target,
       _up = up,
       _verticalSize = verticalSize,
       _zoom = zoom,
       _near = near,
       _far = far {
    this.position = position;
    viewProjection(1);
  }
  @override
  Vec3 get target => _target;
  @override
  set target(Vec3 value) {
    _finite(value, 'target');
    if (value == _target) return;
    _target = value;
    _changed();
  }

  @override
  Vec3 get up => _up;
  @override
  set up(Vec3 value) {
    _finite(value, 'up');
    if (value.length2 == 0) throw ArgumentError('Camera up must be nonzero.');
    if (value == _up) return;
    _up = value;
    _changed();
  }

  double get verticalSize => _verticalSize;
  set verticalSize(double value) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(value, 'verticalSize');
    }
    if (value == _verticalSize) return;
    _verticalSize = value;
    _changed();
  }

  double get zoom => _zoom;
  set zoom(double value) {
    if (!value.isFinite || value <= 0) throw ArgumentError.value(value, 'zoom');
    if (value == _zoom) return;
    _zoom = value;
    _changed();
  }

  double get near => _near;
  set near(double value) {
    if (!value.isFinite || value < 0 || value >= far) {
      throw ArgumentError.value(value, 'near');
    }
    if (value == _near) return;
    _near = value;
    _changed();
  }

  double get far => _far;
  set far(double value) {
    if (!value.isFinite || value <= near) {
      throw ArgumentError.value(value, 'far');
    }
    if (value == _far) return;
    _far = value;
    _changed();
  }

  @override
  OrthographicCamera lookAt(Vec3 target) {
    this.target = target;
    return this;
  }

  @override
  Mat4 projectionMatrix(double aspect) {
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !verticalSize.isFinite ||
        verticalSize <= 0 ||
        !zoom.isFinite ||
        zoom <= 0 ||
        !near.isFinite ||
        !far.isFinite ||
        near < 0 ||
        far <= near) {
      throw ArgumentError('Invalid orthographic projection.');
    }
    final y = 2 * zoom / verticalSize;
    final projection = vm.Matrix4.identity()
      ..setEntry(0, 0, y / aspect)
      ..setEntry(1, 1, y)
      ..setEntry(2, 2, 1 / (near - far))
      ..setEntry(2, 3, near / (near - far));
    return Mat4.fromVectorMath(projection);
  }
}
