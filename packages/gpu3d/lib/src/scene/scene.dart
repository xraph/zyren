import 'dart:async';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../resources/texture_image.dart';
import '../math/vec3.dart';
import '../math/quat.dart';
import '../math/mat4.dart';
part 'revision.dart';

/// Linear RGB channels in [0, 1].
final class Color3 {
  final double r, g, b;
  const Color3(this.r, this.g, this.b);
  factory Color3.hex(int rgb) {
    double linear(int channel) {
      final c = channel / 255;
      return c <= .04045
          ? c / 12.92
          : math.pow((c + .055) / 1.055, 2.4).toDouble();
    }

    return Color3(
      linear((rgb >> 16) & 255),
      linear((rgb >> 8) & 255),
      linear(rgb & 255),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is Color3 && r == other.r && g == other.g && b == other.b;
  @override
  int get hashCode => Object.hash(r, g, b);
  List<double> toList() {
    final values = [r, g, b];
    if (values.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError('RGB channels must be in [0, 1].');
    }
    return values;
  }
}

sealed class MeshMaterial {
  final Color3 color;
  final TextureMap? colorMap;
  MeshMaterial({Color3? color, this.colorMap})
    : color =
          color ??
          (colorMap == null
              ? const Color3(.4, .6, .9)
              : const Color3(1, 1, 1)) {
    this.color.toList();
  }
  bool get unlit;
}

final class DiffuseMaterial extends MeshMaterial {
  DiffuseMaterial({super.color, super.colorMap});
  @override
  bool get unlit => false;
  DiffuseMaterial copyWith({Color3? color, TextureMap? colorMap}) =>
      DiffuseMaterial(
        color: color ?? this.color,
        colorMap: colorMap ?? this.colorMap,
      );
}

final class UnlitMaterial extends MeshMaterial {
  UnlitMaterial({super.color, super.colorMap});
  @override
  bool get unlit => true;
  UnlitMaterial copyWith({Color3? color, TextureMap? colorMap}) =>
      UnlitMaterial(
        color: color ?? this.color,
        colorMap: colorMap ?? this.colorMap,
      );
}

class Object3D with _Revisioned {
  final String? name;
  Object3D({this.name});
  Vec3 _position = Vec3.zero, _scale = Vec3.one;
  Quat _quaternion = Quat.identity;
  bool _visible = true;
  Object3D? _parent;
  final List<Object3D> _children = [];
  Object3D? get parent => _parent;
  List<Object3D> get children => List.unmodifiable(_children);
  Vec3 get position => _position;
  set position(Vec3 value) {
    _finite(value, 'position');
    if (_position == value) return;
    _position = value;
    _changed();
  }

  Vec3 get scale => _scale;
  set scale(Vec3 value) {
    _finite(value, 'scale');
    if (value.x == 0 || value.y == 0 || value.z == 0) {
      throw ArgumentError('Scale must not produce a singular transform.');
    }
    if (_scale == value) return;
    _scale = value;
    _changed();
  }

  Quat get quaternion => _quaternion;
  set quaternion(Quat value) {
    final rotation = value.normalized();
    if (_quaternion == rotation) return;
    _quaternion = rotation;
    _changed();
  }

  bool get visible => _visible;
  set visible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _changed();
  }

  @override
  void _changed() {
    super._changed();
    _parent?._changed();
  }

  T add<T extends Object3D>(T child) {
    for (
      Object3D? ancestor = this;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, child)) {
        throw ArgumentError('A scene graph cannot contain cycles.');
      }
    }
    if (identical(child.parent, this)) return child;
    child._parent?.remove(child);
    _children.add(child);
    child._parent = this;
    _changed();
    return child;
  }

  void remove(Object3D child) {
    if (_children.remove(child)) {
      child._parent = null;
      _changed();
    }
  }

  Mat4 get localMatrix => Mat4.compose(position, quaternion, scale);
  Object3D translate(Vec3 offset) {
    position = position + offset;
    return this;
  }

  Object3D rotateX(double radians) => _rotate(const Vec3(1, 0, 0), radians);
  Object3D rotateY(double radians) => _rotate(const Vec3(0, 1, 0), radians);
  Object3D rotateZ(double radians) => _rotate(const Vec3(0, 0, 1), radians);
  Object3D _rotate(Vec3 axis, double radians) {
    quaternion = quaternion * Quat.axisAngle(axis, radians);
    return this;
  }

  /// Points local +Z toward a target in parent coordinates, using Y as up.
  Object3D lookAt(Vec3 target) {
    final z = (target - position).normalized();
    final up = z.y.abs() > .999 ? const Vec3(0, 0, 1) : const Vec3(0, 1, 0);
    final x = up.cross(z).normalized(), y = z.cross(x);
    final rotation = vm.Matrix3.columns(
      x.toVectorMath(),
      y.toVectorMath(),
      z.toVectorMath(),
    );
    quaternion = Quat.fromVectorMath(vm.Quaternion.fromRotation(rotation));
    return this;
  }
}

class Group extends Object3D {
  Group({super.name});
}

class Mesh extends Object3D {
  final BufferGeometry geometry;
  MeshMaterial _material;
  Mesh(this.geometry, MeshMaterial material, {super.name})
    : _material = material;
  MeshMaterial get material => _material;
  set material(MeshMaterial value) {
    if (identical(_material, value)) return;
    _material = value;
    _changed();
  }
}

abstract class Camera extends Object3D {
  Vec3 get target;
  set target(Vec3 value);
  Vec3 get up;
  set up(Vec3 value);
  Mat4 viewProjection(double aspect);
}

class PerspectiveCamera extends Camera {
  Vec3 _target, _up;
  double _fieldOfView, _near, _far;
  PerspectiveCamera({
    Vec3 position = const Vec3(0, 0, 5),
    Vec3 target = Vec3.zero,
    Vec3 up = const Vec3(0, 1, 0),
    double fieldOfView = 50 * math.pi / 180,
    double near = .1,
    double far = 1000,
  }) : _target = target,
       _up = up,
       _fieldOfView = fieldOfView,
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

  /// Vertical field of view in radians.
  double get fieldOfView => _fieldOfView;
  set fieldOfView(double value) {
    if (!value.isFinite || value <= 0 || value >= math.pi) {
      throw ArgumentError.value(value, 'fieldOfView');
    }
    if (_fieldOfView == value) return;
    _fieldOfView = value;
    _changed();
  }

  double get near => _near;
  set near(double value) {
    if (!value.isFinite || value <= 0 || value >= far) {
      throw ArgumentError.value(value, 'near');
    }
    if (_near == value) return;
    _near = value;
    _changed();
  }

  double get far => _far;
  set far(double value) {
    if (!value.isFinite || value <= near) {
      throw ArgumentError.value(value, 'far');
    }
    if (_far == value) return;
    _far = value;
    _changed();
  }

  @override
  PerspectiveCamera lookAt(Vec3 target) {
    this.target = target;
    return this;
  }

  @override
  Mat4 viewProjection(double aspect) {
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !fieldOfView.isFinite ||
        fieldOfView <= 0 ||
        fieldOfView >= math.pi ||
        !near.isFinite ||
        !far.isFinite ||
        near <= 0 ||
        far <= near ||
        !position.isFinite ||
        !target.isFinite ||
        !up.isFinite) {
      throw ArgumentError('Invalid perspective camera.');
    }
    final direction = position - target;
    if (direction.length2 < 1e-20 || up.length2 < 1e-20) {
      throw ArgumentError(
        'Camera needs a distinct target and a nonzero up vector.',
      );
    }
    final z = direction.normalized(), cross = up.cross(direction);
    if (cross.length2 < 1e-20) {
      throw ArgumentError(
        'Camera up must not be parallel to the view direction.',
      );
    }
    final x = cross.normalized(), y = z.cross(x);
    final view = vm.Matrix4.identity()
      ..setRow(0, vm.Vector4(x.x, x.y, x.z, 0))
      ..setRow(1, vm.Vector4(y.x, y.y, y.z, 0))
      ..setRow(2, vm.Vector4(z.x, z.y, z.z, 0));
    final f = 1 / math.tan(fieldOfView / 2);
    final projection = vm.Matrix4.zero()
      ..setEntry(0, 0, f / aspect)
      ..setEntry(1, 1, f)
      ..setEntry(2, 2, far / (near - far))
      ..setEntry(2, 3, near * far / (near - far))
      ..setEntry(3, 2, -1);
    return Mat4.fromVectorMath(projection * view);
  }
}

void _finite(Vec3 value, String name) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, name, 'Must be finite.');
  }
}

class Scene extends Object3D {
  Color3 _background = Color3.hex(0x101722);
  Vec3 _lightDirection = const Vec3(1, -1, 2);
  double _ambient = .18;
  Color3 get background => _background;
  set background(Color3 value) {
    value.toList();
    if (value == _background) return;
    _background = value;
    _changed();
  }

  Vec3 get lightDirection => _lightDirection;
  set lightDirection(Vec3 value) {
    _finite(value, 'lightDirection');
    if (value.length2 == 0) {
      throw ArgumentError('Light direction must be nonzero.');
    }
    if (value == _lightDirection) return;
    _lightDirection = value;
    _changed();
  }

  double get ambient => _ambient;
  set ambient(double value) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError.value(value, 'ambient');
    }
    if (value == _ambient) return;
    _ambient = value;
    _changed();
  }

  /// Snapshot at the camera origin, before any float32 conversion.
  Map<String, Object> snapshot(
    Camera camera,
    double aspect, {
    Set<int> uploaded = const {},
  }) {
    final meshes = <Map<String, Object>>[];
    final geometries = <int, BufferGeometry>{};
    void visit(Object3D node, vm.Matrix4 parent) {
      if (!node.visible) return;
      final world = parent * node.localMatrix.toVectorMath();
      if (node is Mesh) {
        if (node.material.colorMap != null) {
          throw UnsupportedError(
            'Texture materials require binary scene submissions.',
          );
        }
        final relative = world.clone();
        relative.setTranslation(
          world.getTranslation() - camera.position.toVectorMath(),
        );
        meshes.add({
          'geometry': node.geometry.id,
          'model': relative.storage.toList(),
          'color': node.material.color.toList(),
          'unlit': node.material.unlit,
        });
        geometries[node.geometry.id] = node.geometry;
      }
      for (final child in node._children) {
        visit(child, world);
      }
    }

    visit(this, vm.Matrix4.identity());
    return {
      'version': 1,
      'view_projection': camera.viewProjection(aspect).storage.toList(),
      'background': background.toList(),
      'light_direction': lightDirection.storage.toList(),
      'ambient': ambient,
      'geometries': [
        for (final geometry in geometries.values)
          if (!uploaded.contains(geometry.id)) geometry.toNative(),
      ],
      'meshes': meshes,
    };
  }
}
