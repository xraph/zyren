import 'package:zyren/zyren.dart';

Object? _textureIdentity(TextureMap? map) => map == null
    ? null
    : (
        map.image,
        map.uvSet,
        map.sampler.wrapU,
        map.sampler.wrapV,
        map.sampler.wrapW,
        map.sampler.minFilter,
        map.sampler.magFilter,
        map.sampler.mipFilter,
      );

/// Immutable geometry descriptions. Equal descriptions reuse the CPU geometry.
sealed class SceneGeometry {
  const SceneGeometry();
  const factory SceneGeometry.box({double width, double height, double depth}) =
      _Box;
  const factory SceneGeometry.sphere({
    double radius,
    int widthSegments,
    int heightSegments,
  }) = _Sphere;
  const factory SceneGeometry.plane({double width, double height}) = _Plane;

  /// Borrows geometry you manage, including dynamic and custom geometry.
  const factory SceneGeometry.value(BufferGeometry geometry) = _GeometryValue;
  Object get _identity;
  BufferGeometry create();
  @override
  bool operator ==(Object other) =>
      other is SceneGeometry &&
      runtimeType == other.runtimeType &&
      _identity == other._identity;
  @override
  int get hashCode => Object.hash(runtimeType, _identity);
}

final class _Box extends SceneGeometry {
  final double width, height, depth;
  const _Box({this.width = 1, this.height = 1, this.depth = 1});
  @override
  Object get _identity => (width, height, depth);
  @override
  BufferGeometry create() =>
      BoxGeometry(width: width, height: height, depth: depth);
}

final class _Sphere extends SceneGeometry {
  final double radius;
  final int widthSegments, heightSegments;
  const _Sphere({
    this.radius = 1,
    this.widthSegments = 64,
    this.heightSegments = 32,
  });
  @override
  Object get _identity => (radius, widthSegments, heightSegments);
  @override
  BufferGeometry create() => SphereGeometry(
    radius: radius,
    widthSegments: widthSegments,
    heightSegments: heightSegments,
  );
}

final class _Plane extends SceneGeometry {
  final double width, height;
  const _Plane({this.width = 1, this.height = 1});
  @override
  Object get _identity => (width, height);
  @override
  BufferGeometry create() => PlaneGeometry(width: width, height: height);
}

final class _GeometryValue extends SceneGeometry {
  final BufferGeometry geometry;
  const _GeometryValue(this.geometry);
  @override
  Object get _identity => geometry;
  @override
  BufferGeometry create() => geometry;
}

/// Immutable material descriptions. Texture maps borrow caller-owned images.
sealed class SceneMaterial {
  const SceneMaterial();
  const factory SceneMaterial.unlit({
    Color3 color,
    TextureMap? colorMap,
    MaterialSide side,
    MaterialAlphaMode alphaMode,
    double opacity,
    double alphaCutoff,
    bool depthTest,
    bool vertexColors,
    DepthWrite depthWrite,
  }) = _Unlit;
  const factory SceneMaterial.standard({
    Color3 color,
    double metallic,
    double roughness,
    TextureMap? colorMap,
    MaterialSide side,
    MaterialAlphaMode alphaMode,
    double opacity,
    double alphaCutoff,
    bool depthTest,
    bool vertexColors,
    DepthWrite depthWrite,
    TextureMap? normalMap,
    TextureMap? metallicRoughnessMap,
    TextureMap? occlusionMap,
    TextureMap? emissiveMap,
    double normalScale,
    double normalScaleY,
    double occlusionStrength,
    Color3 emissive,
    double emissiveIntensity,
  }) = _Standard;
  const factory SceneMaterial.value(MeshMaterial material) = _MaterialValue;
  Object get _identity;
  MeshMaterial create();
  @override
  bool operator ==(Object other) =>
      other is SceneMaterial &&
      runtimeType == other.runtimeType &&
      _identity == other._identity;
  @override
  int get hashCode => Object.hash(runtimeType, _identity);
}

final class _Unlit extends SceneMaterial {
  final Color3 color;
  final TextureMap? colorMap;
  final MaterialSide side;
  final MaterialAlphaMode alphaMode;
  final double opacity;
  final double alphaCutoff;
  final bool depthTest;
  final bool vertexColors;
  final DepthWrite depthWrite;
  const _Unlit({
    this.color = const Color3(.4, .6, .9),
    this.colorMap,
    this.side = MaterialSide.doubleSided,
    this.alphaMode = MaterialAlphaMode.opaque,
    this.opacity = 1,
    this.alphaCutoff = .5,
    this.depthTest = true,
    this.vertexColors = false,
    this.depthWrite = DepthWrite.automatic,
  });
  @override
  Object get _identity => (
    color,
    _textureIdentity(colorMap),
    side,
    alphaMode,
    opacity,
    alphaCutoff,
    depthTest,
    vertexColors,
    depthWrite,
  );
  @override
  MeshMaterial create() => UnlitMaterial(
    color: color,
    colorMap: colorMap,
    side: side,
    alphaMode: alphaMode,
    opacity: opacity,
    alphaCutoff: alphaCutoff,
    depthTest: depthTest,
    vertexColors: vertexColors,
    depthWrite: depthWrite,
  );
}

final class _Standard extends SceneMaterial {
  final Color3 color;
  final double metallic;
  final double roughness;
  final TextureMap? colorMap;
  final MaterialSide side;
  final MaterialAlphaMode alphaMode;
  final double opacity;
  final double alphaCutoff;
  final bool depthTest;
  final bool vertexColors;
  final DepthWrite depthWrite;
  final TextureMap? normalMap;
  final TextureMap? metallicRoughnessMap;
  final TextureMap? occlusionMap;
  final TextureMap? emissiveMap;
  final double normalScale;
  final double normalScaleY;
  final double occlusionStrength;
  final Color3 emissive;
  final double emissiveIntensity;
  const _Standard({
    this.color = const Color3(1, 1, 1),
    this.metallic = 0,
    this.roughness = 1,
    this.colorMap,
    this.side = MaterialSide.doubleSided,
    this.alphaMode = MaterialAlphaMode.opaque,
    this.opacity = 1,
    this.alphaCutoff = .5,
    this.depthTest = true,
    this.vertexColors = false,
    this.depthWrite = DepthWrite.automatic,
    this.normalMap,
    this.metallicRoughnessMap,
    this.occlusionMap,
    this.emissiveMap,
    this.normalScale = 1,
    this.normalScaleY = 1,
    this.occlusionStrength = 1,
    this.emissive = const Color3(0, 0, 0),
    this.emissiveIntensity = 1,
  });
  @override
  Object get _identity => (
    color,
    metallic,
    roughness,
    _textureIdentity(colorMap),
    side,
    alphaMode,
    opacity,
    alphaCutoff,
    depthTest,
    vertexColors,
    depthWrite,
    _textureIdentity(normalMap),
    _textureIdentity(metallicRoughnessMap),
    _textureIdentity(occlusionMap),
    _textureIdentity(emissiveMap),
    normalScale,
    normalScaleY,
    occlusionStrength,
    emissive,
    emissiveIntensity,
  );
  @override
  MeshMaterial create() => StandardMaterial(
    color: color,
    metallic: metallic,
    roughness: roughness,
    colorMap: colorMap,
    side: side,
    alphaMode: alphaMode,
    opacity: opacity,
    alphaCutoff: alphaCutoff,
    depthTest: depthTest,
    vertexColors: vertexColors,
    depthWrite: depthWrite,
    normalMap: normalMap,
    metallicRoughnessMap: metallicRoughnessMap,
    occlusionMap: occlusionMap,
    emissiveMap: emissiveMap,
    normalScale: normalScale,
    normalScaleY: normalScaleY,
    occlusionStrength: occlusionStrength,
    emissive: emissive,
    emissiveIntensity: emissiveIntensity,
  );
}

final class _MaterialValue extends SceneMaterial {
  final MeshMaterial material;
  const _MaterialValue(this.material);
  @override
  Object get _identity => material;
  @override
  MeshMaterial create() => material;
}

/// Camera configuration for SceneCanvas. Field of view is in radians.
/// Equal descriptions retain the camera, including changes from orbit controls.
sealed class SceneCamera {
  const SceneCamera();
  const factory SceneCamera.perspective({
    Vec3 position,
    Vec3 target,
    double fieldOfView,
    double near,
    double far,
  }) = _Perspective;
  const factory SceneCamera.orthographic({
    Vec3 position,
    Vec3 target,
    double verticalSize,
    double near,
    double far,
  }) = _Orthographic;
  const factory SceneCamera.value(Camera camera) = _CameraValue;
  Object get _identity;
  Camera create();
  @override
  bool operator ==(Object other) =>
      other is SceneCamera &&
      runtimeType == other.runtimeType &&
      _identity == other._identity;
  @override
  int get hashCode => Object.hash(runtimeType, _identity);
}

final class _Perspective extends SceneCamera {
  final Vec3 position, target;
  final double fieldOfView, near, far;
  const _Perspective({
    this.position = const Vec3(0, 0, 5),
    this.target = Vec3.zero,
    this.fieldOfView = 0.8726646259971648,
    this.near = .1,
    this.far = 1000,
  });
  @override
  Object get _identity => (position, target, fieldOfView, near, far);
  @override
  Camera create() => PerspectiveCamera(
    position: position,
    target: target,
    fieldOfView: fieldOfView,
    near: near,
    far: far,
  );
}

final class _Orthographic extends SceneCamera {
  final Vec3 position, target;
  final double verticalSize, near, far;
  const _Orthographic({
    this.position = const Vec3(0, 0, 5),
    this.target = Vec3.zero,
    this.verticalSize = 4,
    this.near = 0,
    this.far = 1000,
  });
  @override
  Object get _identity => (position, target, verticalSize, near, far);
  @override
  Camera create() => OrthographicCamera(
    position: position,
    target: target,
    verticalSize: verticalSize,
    near: near,
    far: far,
  );
}

final class _CameraValue extends SceneCamera {
  final Camera camera;
  const _CameraValue(this.camera);
  @override
  Object get _identity => camera;
  @override
  Camera create() => camera;
}
