import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart';
import '../geometry/geometry.dart';

/// Linear RGB channels in [0, 1].
class Color3 {
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
  List<double> toList() {
    final values = [r, g, b];
    if (values.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError('RGB channels must be in [0, 1].');
    }
    return values;
  }
}

class MeshMaterial {
  Color3 color;
  bool unlit;
  MeshMaterial({this.color = const Color3(.4, .6, .9), this.unlit = false});
}

class Object3D {
  final Vector3 position = Vector3.zero();
  final Quaternion quaternion = Quaternion.identity();
  final Vector3 scale = Vector3.all(1);
  bool visible = true;
  Object3D? _parent;
  final List<Object3D> _children = [];
  Object3D? get parent => _parent;
  List<Object3D> get children => List.unmodifiable(_children);

  void add(Object3D child) {
    for (
      Object3D? ancestor = this;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, child)) {
        throw ArgumentError('A scene graph cannot contain cycles.');
      }
    }
    child._parent?.remove(child);
    _children.add(child);
    child._parent = this;
  }

  void remove(Object3D child) {
    if (_children.remove(child)) child._parent = null;
  }

  Matrix4 get localMatrix => Matrix4.compose(position, quaternion, scale);
}

class Mesh extends Object3D {
  final BufferGeometry geometry;
  final MeshMaterial material;
  Mesh(this.geometry, this.material);
}

class PerspectiveCamera {
  final Vector3 position;
  final Vector3 target;
  final Vector3 up;
  double fieldOfView, near, far;
  PerspectiveCamera({
    Vector3? position,
    Vector3? target,
    Vector3? up,
    this.fieldOfView = 50,
    this.near = .1,
    this.far = 1000,
  }) : position = position ?? Vector3(0, 0, 5),
       target = target ?? Vector3.zero(),
       up = up ?? Vector3(0, 1, 0);

  Matrix4 viewProjection(double aspect) {
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !fieldOfView.isFinite ||
        fieldOfView <= 0 ||
        fieldOfView >= 179 ||
        !near.isFinite ||
        !far.isFinite ||
        near <= 0 ||
        far <= near ||
        position.storage.any((v) => !v.isFinite) ||
        target.storage.any((v) => !v.isFinite) ||
        up.storage.any((v) => !v.isFinite)) {
      throw ArgumentError('Invalid perspective camera.');
    }
    final z = position - target;
    if (z.length2 < 1e-20 || up.length2 < 1e-20) {
      throw ArgumentError(
        'Camera needs a distinct target and a nonzero up vector.',
      );
    }
    z.normalize();
    final x = up.cross(z);
    if (x.length2 < 1e-20) {
      throw ArgumentError(
        'Camera up must not be parallel to the view direction.',
      );
    }
    x.normalize();
    final y = z.cross(x);
    final view = Matrix4.identity()
      ..setRow(0, Vector4(x.x, x.y, x.z, 0))
      ..setRow(1, Vector4(y.x, y.y, y.z, 0))
      ..setRow(2, Vector4(z.x, z.y, z.z, 0));
    final f = 1 / math.tan(fieldOfView * math.pi / 360);
    final projection = Matrix4.zero()
      ..setEntry(0, 0, f / aspect)
      ..setEntry(1, 1, f)
      ..setEntry(2, 2, far / (near - far))
      ..setEntry(2, 3, near * far / (near - far))
      ..setEntry(3, 2, -1);
    return projection * view;
  }
}

class Scene extends Object3D {
  Color3 background = Color3.hex(0x101722);
  Vector3 lightDirection = Vector3(1, -1, 2);
  double ambient = .18;

  /// Snapshot at the camera origin, before any float32 conversion.
  Map<String, Object> snapshot(
    PerspectiveCamera camera,
    double aspect, {
    Set<int> uploaded = const {},
  }) {
    final meshes = <Map<String, Object>>[];
    final geometries = <int, BufferGeometry>{};
    void visit(Object3D node, Matrix4 parent) {
      if (!node.visible) return;
      final world = parent * node.localMatrix;
      if (node is Mesh) {
        final relative = world.clone();
        relative.setTranslation(world.getTranslation() - camera.position);
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

    visit(this, Matrix4.identity());
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
