part of 'scene.dart';

/// A world-space ray with a normalized direction and distances in scene units.
final class CameraRay {
  final Vec3 origin, direction;
  CameraRay(this.origin, Vec3 direction) : direction = direction.normalized() {
    _finite(origin, 'origin');
  }
  Vec3 at(double distance) {
    if (!distance.isFinite) throw ArgumentError.value(distance, 'distance');
    return origin + direction * distance;
  }
}

/// Explicit orthographic bounds, independent of the viewport's aspect ratio.
/// Positions, target and up follow the same world-space contract as perspective.
class OrthographicCamera extends Camera {
  Vec3 _target, _up;
  double _left, _right, _bottom, _top, _near, _far, _zoom;
  OrthographicCamera({
    Vec3 position = const Vec3(0, 0, 5),
    Vec3 target = Vec3.zero,
    Vec3 up = const Vec3(0, 1, 0),
    double left = -1,
    double right = 1,
    double bottom = -1,
    double top = 1,
    double near = 0,
    double far = 1000,
    double zoom = 1,
    super.depthStrategy,
  }) : _target = target,
       _up = up,
       _left = left,
       _right = right,
       _bottom = bottom,
       _top = top,
       _near = near,
       _far = far,
       _zoom = zoom {
    this.position = position;
    viewProjection(1);
  }
  @override
  Vec3 get target => _target;
  @override
  set target(Vec3 value) {
    _finite(value, 'target');
    if (_target == value) return;
    _target = value;
    _changed();
  }

  @override
  Vec3 get up => _up;
  @override
  set up(Vec3 value) {
    _finite(value, 'up');
    if (value.length2 == 0) throw ArgumentError('Camera up must be nonzero.');
    if (_up == value) return;
    _up = value;
    _changed();
  }

  double get left => _left;
  set left(double value) => setFrustum(left: value);
  double get right => _right;
  set right(double value) => setFrustum(right: value);
  double get bottom => _bottom;
  set bottom(double value) => setFrustum(bottom: value);
  double get top => _top;
  set top(double value) => setFrustum(top: value);
  double get near => _near;
  set near(double value) => setClippingRange(value, far);
  double get far => _far;
  set far(double value) => setClippingRange(near, value);
  double get zoom => _zoom;
  set zoom(double value) {
    if (!value.isFinite || value <= 0) throw ArgumentError.value(value, 'zoom');
    if (_zoom == value) return;
    _zoom = value;
    _changed();
  }

  void setFrustum({double? left, double? right, double? bottom, double? top}) {
    final l = left ?? _left, r = right ?? _right;
    final b = bottom ?? _bottom, t = top ?? _top;
    _validateBounds(l, r, b, t);
    if (_left == l && _right == r && _bottom == b && _top == t) return;
    _left = l;
    _right = r;
    _bottom = b;
    _top = t;
    _changed();
  }

  void setClippingRange(double near, double far) {
    _validateClipping(near, far, allowZeroNear: true);
    if (_near == near && _far == far) return;
    _near = near;
    _far = far;
    _changed();
  }

  @override
  OrthographicCamera lookAt(Vec3 target) {
    this.target = target;
    return this;
  }

  @override
  Mat4 viewProjection(double aspect) {
    if (!aspect.isFinite || aspect <= 0 || !zoom.isFinite || zoom <= 0) {
      throw ArgumentError('Invalid orthographic camera aspect or zoom.');
    }
    _validateBounds(left, right, bottom, top);
    _validateClipping(near, far, allowZeroNear: true);
    final axes = _cameraAxes(this);
    final view = vm.Matrix4.identity()
      ..setRow(0, vm.Vector4(axes.right.x, axes.right.y, axes.right.z, 0))
      ..setRow(1, vm.Vector4(axes.up.x, axes.up.y, axes.up.z, 0))
      ..setRow(2, vm.Vector4(axes.back.x, axes.back.y, axes.back.z, 0));
    final width = (right - left) / zoom, height = (top - bottom) / zoom;
    final cx = (left + right) / 2, cy = (bottom + top) / 2;
    final projection = vm.Matrix4.identity()
      ..setEntry(0, 0, 2 / width)
      ..setEntry(1, 1, 2 / height)
      ..setEntry(
        2,
        2,
        depthStrategy == DepthStrategy.reversed
            ? 1 / (far - near)
            : 1 / (near - far),
      )
      ..setEntry(0, 3, -2 * cx / width)
      ..setEntry(1, 3, -2 * cy / height)
      ..setEntry(
        2,
        3,
        depthStrategy == DepthStrategy.reversed
            ? far / (far - near)
            : near / (near - far),
      );
    return Mat4.fromVectorMath(projection * view);
  }

  @override
  CameraRay rayFromNdc(double x, double y, double aspect) {
    viewProjection(aspect);
    final axes = _cameraAxes(this);
    final offsetX = (left + right) / 2 + x * (right - left) / (2 * zoom);
    final offsetY = (bottom + top) / 2 + y * (top - bottom) / (2 * zoom);
    return CameraRay(
      position + axes.right * offsetX + axes.up * offsetY,
      -axes.back,
    );
  }
}

({Vec3 right, Vec3 up, Vec3 back}) _cameraAxes(Camera camera) {
  final back = (camera.position - camera.target).normalized();
  final right = camera.up.cross(back).normalized();
  return (right: right, up: back.cross(right), back: back);
}

Vec3 _transformPoint(Mat4 matrix, Vec3 point) {
  final v = matrix.toVectorMath() * vm.Vector4(point.x, point.y, point.z, 1);
  if (!v.w.isFinite || v.w == 0) {
    throw ArgumentError('Point projects to infinity.');
  }
  final result = Vec3(v.x / v.w, v.y / v.w, v.z / v.w);
  _finite(result, 'projectedPoint');
  return result;
}

void _validateClipping(double near, double far, {required bool allowZeroNear}) {
  if (!near.isFinite ||
      !far.isFinite ||
      far <= near ||
      near < 0 ||
      (!allowZeroNear && near == 0)) {
    throw ArgumentError('Invalid camera clipping range.');
  }
}

void _validateBounds(double left, double right, double bottom, double top) {
  if ([left, right, bottom, top].any((v) => !v.isFinite) ||
      left >= right ||
      bottom >= top) {
    throw ArgumentError('Orthographic bounds must be finite and ordered.');
  }
}
