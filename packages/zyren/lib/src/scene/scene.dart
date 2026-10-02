import 'dart:async';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../spatial/bounds.dart';
import 'layer_mask.dart';
import '../rendering/depth_strategy.dart';
import '../resources/resource_scope.dart'
    show RenderSettings, ScreenEffect, VolumeEnvironmentMap;
import '../plugins/registration.dart';
export '../resources/resource_scope.dart' show RenderSettings, ToneMapping;
import '../materials/material.dart';
import '../math/color3.dart';
export '../materials/material.dart';
export '../math/color3.dart';
import '../math/vec3.dart';
import '../math/quat.dart';
import '../math/mat4.dart';
part 'revision.dart';
part 'deformation.dart';
part '../geometry/skin.dart';
part '../lights/punctual_light.dart';
part '../lights/hemisphere_light.dart';
part '../lights/rect_area_light.dart';
part '../lights/shadow_settings.dart';
part 'camera_projection.dart';
part 'primitives.dart';
part 'instanced_mesh.dart';
part 'clipping_plane.dart';
part 'scene_outline.dart';
part 'fragment_coverage.dart';

class Object3D with _Revisioned {
  static int _nextObjectId = 1;

  /// Stable within this isolate, across scene edits and reparenting.
  final int id = _nextObjectId++;

  final String? name;
  Object3D({this.name});
  Vec3 _position = Vec3.zero, _scale = Vec3.one;
  Quat _quaternion = Quat.identity;
  bool _visible = true;
  bool _clippingEnabled = true;
  bool _outlineEnabled = true;

  /// False excludes this subtree from inherited scene outlines.
  bool get outlineEnabled => _outlineEnabled;
  set outlineEnabled(bool value) {
    if (_outlineEnabled == value) return;
    _outlineEnabled = value;
    _changed();
  }

  /// False exempts this object and its descendants from scene section planes.
  bool get clippingEnabled => _clippingEnabled;
  set clippingEnabled(bool value) {
    if (_clippingEnabled == value) return;
    _clippingEnabled = value;
    _changed();
  }

  LayerMask _layers = LayerMask.only(0);
  LayerMask get layers => _layers;
  set layers(LayerMask value) {
    if (value == _layers) return;
    _layers = value;
    _changed();
  }

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

  Mat4 get worldMatrix {
    var result = localMatrix;
    for (var node = parent; node != null; node = node.parent) {
      result = node.localMatrix * result;
    }
    return result;
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

class Mesh extends Object3D with _MeshDeformation {
  bool _frustumCulled = true;
  Bounds3? _cullingBounds;

  /// Allows camera-frustum rejection of this mesh's color draw.
  /// Shadow participation and resource ownership are independent.
  bool get frustumCulled => _frustumCulled;
  set frustumCulled(bool value) {
    if (value == _frustumCulled) return;
    _frustumCulled = value;
    _changed();
  }

  /// Optional mesh-local bounds after deformation and instance transforms.
  /// Null infers built-in triangle bounds. Custom shaders and expanded
  /// primitives stay visible until you supply conservative bounds here.
  Bounds3? get cullingBounds => _cullingBounds;
  set cullingBounds(Bounds3? value) {
    if (identical(value, _cullingBounds)) return;
    _cullingBounds = value;
    _changed();
  }

  bool _castShadow = false, _receiveShadow = false;
  bool get castShadow => _castShadow;
  set castShadow(bool value) {
    if (_castShadow == value) return;
    _castShadow = value;
    _changed();
  }

  bool get receiveShadow => _receiveShadow;
  set receiveShadow(bool value) {
    if (_receiveShadow == value) return;
    _receiveShadow = value;
    _changed();
  }

  @override
  final BufferGeometry geometry;
  MeshMaterial _material;
  FragmentCoverage _fragmentCoverage = const FragmentCoverage.full();
  FragmentCoverage get fragmentCoverage => _fragmentCoverage;
  set fragmentCoverage(FragmentCoverage value) {
    if (!value.isFull && _material is ShaderMaterial) {
      throw UnsupportedError(
        'Custom shaders do not provide a fragment coverage hook.',
      );
    }
    if (_fragmentCoverage == value) return;
    _fragmentCoverage = value;
    _changed();
  }

  int _renderOrder = 0;
  Mesh(this.geometry, MeshMaterial material, {super.name, int renderOrder = 0})
    : _material = material {
    _validateMaterial(material);
    this.renderOrder = renderOrder;
    watchGeometry(geometry, this, _geometryChanged);
  }

  /// Draw order within the opaque/mask or blended queue. Lower values draw first.
  int get renderOrder => _renderOrder;
  set renderOrder(int value) {
    RangeError.checkValueInInterval(
      value,
      -0x80000000,
      0x7fffffff,
      'renderOrder',
    );
    if (_renderOrder == value) return;
    _renderOrder = value;
    _changed();
  }

  void _validateMaterial(MeshMaterial material) {
    final kind = switch (geometry.topology) {
      GeometryTopology.triangles => 0,
      GeometryTopology.lineSegments || GeometryTopology.lineStrip => 1,
      GeometryTopology.points => 2,
    };
    if (material.primitiveKind != kind) {
      throw ArgumentError('Material must match the geometry topology.');
    }
  }

  static void _geometryChanged(Object owner) => (owner as Mesh)._changed();
  MeshMaterial get material => _material;
  set material(MeshMaterial value) {
    _validateMaterial(value);
    if (identical(_material, value)) return;
    _material = value;
    _changed();
  }
}

abstract class Camera extends Object3D {
  Camera({DepthStrategy depthStrategy = DepthStrategy.standard})
    : _depthStrategy = depthStrategy;
  DepthStrategy _depthStrategy;
  DepthStrategy get depthStrategy => _depthStrategy;
  set depthStrategy(DepthStrategy value) {
    if (_depthStrategy == value) return;
    _depthStrategy = value;
    _changed();
  }

  Vec3 get target;
  set target(Vec3 value);
  Vec3 get up;
  set up(Vec3 value);
  Mat4 projectionMatrix(double aspect) {
    final axes = _cameraAxes(this);
    final rotation = vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(axes.right.x, axes.right.y, axes.right.z, 0))
      ..setColumn(1, vm.Vector4(axes.up.x, axes.up.y, axes.up.z, 0))
      ..setColumn(2, vm.Vector4(axes.back.x, axes.back.y, axes.back.z, 0));
    return Mat4.fromVectorMath(
      viewProjection(aspect).toVectorMath() * rotation,
    );
  }

  Mat4 viewProjection(double aspect) {
    final projection = projectionMatrix(aspect).toVectorMath();
    if (!position.isFinite || !target.isFinite || !up.isFinite) {
      throw ArgumentError('Invalid camera.');
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
    return Mat4.fromVectorMath(projection * view);
  }

  /// Projects a world point to normalized coordinates, with native depth 0..1.
  Vec3 projectPoint(Vec3 world, double aspect) {
    _finite(world, 'world');
    return _transformPoint(viewProjection(aspect), world - position);
  }

  /// Converts normalized coordinates with native depth 0..1 into world space.
  Vec3 unprojectPoint(Vec3 normalized, double aspect) {
    _finite(normalized, 'normalized');
    return position +
        _transformPoint(viewProjection(aspect).inverted(), normalized);
  }

  /// Returns a world ray through NDC X/Y. Custom projections start at near.
  CameraRay rayFromNdc(double x, double y, double aspect) {
    final inverse = viewProjection(aspect).inverted();
    final near = _transformPoint(inverse, Vec3(x, y, depthStrategy.nearDepth));
    final far = _transformPoint(inverse, Vec3(x, y, depthStrategy.farDepth));
    return CameraRay(position + near, far - near);
  }
}

class PerspectiveCamera extends Camera {
  Vec3 _target, _up;
  double _fieldOfView, _near, _far, _zoom;
  PerspectiveCamera({
    Vec3 position = const Vec3(0, 0, 5),
    Vec3 target = Vec3.zero,
    Vec3 up = const Vec3(0, 1, 0),
    double fieldOfView = 50 * math.pi / 180,
    double near = .1,
    double far = 1000,
    double zoom = 1,
    super.depthStrategy,
  }) : _target = target,
       _up = up,
       _fieldOfView = fieldOfView,
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

  double get zoom => _zoom;
  set zoom(double value) {
    if (!value.isFinite || value <= 0) throw ArgumentError.value(value, 'zoom');
    if (_zoom == value) return;
    _zoom = value;
    _changed();
  }

  /// Changes both clipping planes atomically, including disjoint ranges.
  void setClippingRange(double near, double far) {
    _validateClipping(near, far, allowZeroNear: false);
    if (_near == near && _far == far) return;
    _near = near;
    _far = far;
    _changed();
  }

  @override
  CameraRay rayFromNdc(double x, double y, double aspect) {
    viewProjection(aspect);
    final axes = _cameraAxes(this), tangent = math.tan(fieldOfView / 2) / zoom;
    return CameraRay(
      position,
      axes.right * (x * tangent * aspect) + axes.up * (y * tangent) - axes.back,
    );
  }

  @override
  PerspectiveCamera lookAt(Vec3 target) {
    this.target = target;
    return this;
  }

  @override
  Mat4 projectionMatrix(double aspect) {
    if (!aspect.isFinite || aspect <= 0) {
      throw ArgumentError.value(aspect, 'aspect');
    }
    final f = zoom / math.tan(fieldOfView / 2);
    final projection = vm.Matrix4.zero()
      ..setEntry(0, 0, f / aspect)
      ..setEntry(1, 1, f)
      ..setEntry(
        2,
        2,
        depthStrategy == DepthStrategy.reversed
            ? near / (far - near)
            : far / (near - far),
      )
      ..setEntry(
        2,
        3,
        depthStrategy == DepthStrategy.reversed
            ? near * far / (far - near)
            : near * far / (near - far),
      )
      ..setEntry(3, 2, -1);
    return Mat4.fromVectorMath(projection);
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
        !zoom.isFinite ||
        zoom <= 0 ||
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
    final projection = projectionMatrix(aspect).toVectorMath();
    return Mat4.fromVectorMath(projection * view);
  }
}

void _finite(Vec3 value, String name) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, name, 'Must be finite.');
  }
}

/// Owns one effect slot. Replacements keep its order and do not need a free slot.
final class EffectRegistration extends Registration {
  final void Function(ScreenEffect, bool) _replace;
  EffectRegistration._(super.release, this._replace);

  /// Use [invalidate] false when rebinding temporal buffers in beforeRender.
  /// The current frame uses the replacement without scheduling another frame.
  void replace(ScreenEffect effect, {bool invalidate = true}) {
    if (isDisposed) throw StateError('Effect registration has closed.');
    if (effect.isClosed) throw StateError('Effect owner has closed.');
    _replace(effect, invalidate);
  }
}

/// Owns the scene's environment slot until disposal restores its settings fallback.
final class EnvironmentRegistration extends Registration {
  final void Function(VolumeEnvironmentMap) _replace;
  EnvironmentRegistration._(super.release, this._replace);
  void replace(VolumeEnvironmentMap map) {
    if (isDisposed) throw StateError('Environment registration has closed.');
    if (map.isClosed) {
      throw StateError('Environment resource owner has closed.');
    }
    _replace(map);
  }
}

class Scene extends Object3D {
  List<ClippingPlane> _clippingPlanes = const [];
  SceneOutline? _outline;
  SceneOutline? get outline => _outline;
  set outline(SceneOutline? value) {
    if (identical(value, _outline)) return;
    _outline = value;
    _changed();
  }

  /// Up to six world-space half-spaces, intersected without generating caps.
  List<ClippingPlane> get clippingPlanes => _clippingPlanes;
  set clippingPlanes(List<ClippingPlane> value) {
    if (identical(value, _clippingPlanes)) return;
    if (value.length > 6) {
      throw ArgumentError('A scene supports at most six clipping planes.');
    }
    _clippingPlanes = List.unmodifiable(value);
    _changed();
  }

  RenderSettings _renderSettings = RenderSettings();
  final _effects = <Object, ({int order, ScreenEffect effect})>{};
  final _transparentBackgroundEffects = <Object>{};

  /// Effective clear alpha while an effect supplies the visible background.
  double get backgroundOpacity => _renderSettings.backgroundAlpha;
  set backgroundOpacity(double value) {
    renderSettings = renderSettings.copyWith(backgroundAlpha: value);
  }

  double get backgroundAlpha => _transparentBackgroundEffects.isEmpty
      ? _renderSettings.backgroundAlpha
      : 0;
  VolumeEnvironmentMap? _environment;
  VolumeEnvironmentMap? get environment =>
      _environment ?? _renderSettings.environment;
  EnvironmentRegistration addEnvironment(VolumeEnvironmentMap map) {
    if (map.isClosed) {
      throw StateError('Environment resource owner has closed.');
    }
    if (_environment != null) {
      throw StateError(
        'A lighting plugin already owns this scene environment.',
      );
    }
    _environment = map;
    _changed();
    return EnvironmentRegistration._(
      () {
        _environment = null;
        _changed();
      },
      (replacement) {
        _environment = replacement;
        _changed();
      },
    );
  }

  RenderSettings get renderSettings => _renderSettings;
  List<ScreenEffect> get effects {
    final ordered =
        [
          for (final effect in _renderSettings.effects)
            (order: 0, effect: effect),
          ..._effects.values,
        ].indexed.toList()..sort((a, b) {
          final stage = a.$2.effect.stage.index.compareTo(
            b.$2.effect.stage.index,
          );
          if (stage != 0) return stage;
          final order = a.$2.order.compareTo(b.$2.order);
          return order == 0 ? a.$1.compareTo(b.$1) : order;
        });
    return List.unmodifiable(ordered.map((entry) => entry.$2.effect));
  }

  /// Request a transparent clear when your effect composites its own sky or
  /// backdrop behind scene coverage. Disposing the slot restores the setting.
  /// HDR effects run before display effects. Within each stage, lower [order]
  /// values run first. Settings effects have order zero; ties
  /// retain insertion order, with settings before registered effects.
  EffectRegistration addEffect(
    ScreenEffect effect, {
    bool requiresTransparentBackground = false,
    int order = 0,
  }) {
    RangeError.checkValueInInterval(order, -32768, 32767, 'order');
    if (effect.isClosed) throw StateError('Effect owner has closed.');
    if (effects.length >= 32) {
      throw StateError('At most 32 effects are supported.');
    }
    final key = Object();
    _effects[key] = (order: order, effect: effect);
    if (requiresTransparentBackground) _transparentBackgroundEffects.add(key);
    _changed();
    return EffectRegistration._(
      () {
        _effects.remove(key);
        _transparentBackgroundEffects.remove(key);
        _changed();
      },
      (replacement, invalidate) {
        _effects[key] = (order: order, effect: replacement);
        if (invalidate) {
          _changed();
        } else {
          _revision++;
        }
      },
    );
  }

  set renderSettings(RenderSettings value) {
    if (value.effects.length + _effects.length > 32) {
      throw StateError('At most 32 effects are supported.');
    }
    if (identical(value, _renderSettings)) return;
    _renderSettings = value;
    _changed();
  }

  Color3? _background;
  Vec3 _lightDirection = const Vec3(1, -1, 2);
  double _ambient = .18;
  Color3? get background => _background;
  set background(Color3? value) {
    value?.toList();
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
    if (camera.depthStrategy != DepthStrategy.standard) {
      throw UnsupportedError(
        'Reversed depth requires binary scene submissions.',
      );
    }
    if (renderSettings.enabled || _effects.isNotEmpty || environment != null) {
      throw UnsupportedError(
        'Postprocessing requires binary scene submissions.',
      );
    }
    final meshes = <Map<String, Object>>[];
    final geometries = <int, GeometrySnapshot>{};
    void visit(Object3D node, vm.Matrix4 parent) {
      if (!node.visible) return;
      if (node is Light) {
        throw UnsupportedError(
          'Physical lights require binary scene submissions.',
        );
      }
      final world = parent * node.localMatrix.toVectorMath();
      if (node is Mesh) {
        if (node.castShadow ||
            node.material.colorMap != null ||
            node.material is ShaderMaterial ||
            node.material is StandardMaterial) {
          throw UnsupportedError(
            'Texture materials require binary scene submissions.',
          );
        }
        final relative = world.clone();
        relative.setTranslation(
          world.getTranslation() - camera.position.toVectorMath(),
        );
        meshes.add({
          'geometry': node.geometry.capture().id,
          'model': relative.storage.toList(),
          'color': node.material.color.toList(),
          'unlit': node.material.unlit,
          'side': node.material.side.index,
          'alpha_mode': node.material.alphaMode.index,
          'opacity': node.material.opacity,
          'alpha_cutoff': node.material.alphaCutoff,
          'coverage': [
            node.fragmentCoverage.lower,
            node.fragmentCoverage.upper,
          ],
          'depth_test': node.material.depthTest,
          'depth_write': node.material.writesDepth,
          'render_order': node.renderOrder,
          'primitive_kind': node.material.primitiveKind,
          'primitive_size': node.material.primitiveSize,
          'size_units': node.material.sizeUnits.index,
          'point_shape': node.material.pointShape.index,
        });
        final geometry = node.geometry.capture();
        geometries[geometry.id] = geometry;
      }
      for (final child in node._children) {
        visit(child, world);
      }
    }

    visit(this, vm.Matrix4.identity());
    return {
      'version': 1,
      'view_projection': camera.viewProjection(aspect).storage.toList(),
      'background': background?.toList() ?? [0.0, 0.0, 0.0],
      'background_alpha': background == null ? 0.0 : backgroundOpacity,
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
