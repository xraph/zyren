part of '../resources/resource_scope.dart';

enum MeshVertexLayout {
  positionNormal,
  positionNormalUv,
  positionNormalUvTangent,
  positionNormalColor,
  positionNormalUvColor,
  positionNormalUvTangentColor;

  bool get hasUv => index == 1 || index == 2 || index == 4 || index == 5;
  bool get hasTangents => index == 2 || index == 5;
  bool get hasColors => index >= 3;
}

/// Engine-managed vertex data required by a compiled mesh program.
enum MeshShaderGeometry {
  rigid,
  instanced,
  deformed,
  deformedInstanced;

  bool get usesInstancing => index.isOdd;
  bool get usesDeformation => index >= 2;
}

/// Read-only frame inputs reserved at group three for opted-in programs.
enum MeshSceneInputs { none, opaqueColorDepth }

/// Include this prelude in WGSL to use the scene's group-zero uniform layout.
/// Matrices use camera-relative world coordinates. Fragment output is linear.
abstract final class MeshShaderInterface {
  /// Group-two skin and morph buffers, shared with the native material kernel.
  /// Call deform_vertex before applying an instance or model transform.
  static const deformation = meshDeformationWgsl;

  /// Fragment-only opaque HDR color and resolved depth from this frame and view.
  /// Coordinates use top-left view pixels, even when capture resolution is scaled.
  /// Transparent objects and every
  /// scene-input consumer are absent. Depth is WebGPU 0..1; depthInfo.x is clear
  /// depth and depthInfo.y is one for reversed depth. Geometry behind the camera
  /// or clear depth has no reconstructed surface. Matrices are camera-relative.
  static const sceneInputs = '''
struct MeshSceneUniforms {
  inverseViewProjection: mat4x4<f32>,
  viewport: vec4<f32>,
  depthInfo: vec4<f32>,
};
@group(3) @binding(0) var<uniform> meshScene: MeshSceneUniforms;
@group(3) @binding(1) var meshOpaqueColor: texture_2d<f32>;
@group(3) @binding(2) var meshOpaqueDepth: texture_depth_2d;
fn meshScenePixel(pixel: vec2<f32>) -> vec2<i32> {
  let size=vec2<i32>(textureDimensions(meshOpaqueDepth));
  return clamp(vec2<i32>(floor(pixel*meshScene.viewport.zw*vec2<f32>(size))),vec2(0),size-vec2(1));
}
fn meshSceneColor(pixel: vec2<f32>) -> vec4<f32> {
  return textureLoad(meshOpaqueColor,meshScenePixel(pixel),0);
}
fn meshSceneDepth(pixel: vec2<f32>) -> f32 {
  return textureLoad(meshOpaqueDepth,meshScenePixel(pixel),0);
}
fn meshSceneHasSurface(depth: f32) -> bool {
  return depth != meshScene.depthInfo.x;
}
fn meshScenePosition(pixel: vec2<f32>,depth: f32) -> vec3<f32> {
  let uv=(vec2<f32>(meshScenePixel(pixel))+vec2(0.5))/vec2<f32>(textureDimensions(meshOpaqueDepth));
  let p=meshScene.inverseViewProjection*vec4(uv.x*2.-1.,1.-uv.y*2.,depth,1.);
  return p.xyz/p.w;
}
''';

  /// Per-instance transforms at locations 6 through 12 and linear RGB at 13.
  static const instancing = '''
struct MeshInstanceInput {
  @location(6) model0: vec4<f32>,
  @location(7) model1: vec4<f32>,
  @location(8) model2: vec4<f32>,
  @location(9) model3: vec4<f32>,
  @location(10) normal0: vec4<f32>,
  @location(11) normal1: vec4<f32>,
  @location(12) normal2: vec4<f32>,
  @location(13) color: vec3<f32>,
};
fn meshInstanceMatrix(instance: MeshInstanceInput) -> mat4x4<f32> {
  return mat4x4(instance.model0, instance.model1, instance.model2, instance.model3);
}
fn meshInstanceNormalMatrix(instance: MeshInstanceInput) -> mat3x3<f32> {
  return mat3x3(instance.normal0.xyz, instance.normal1.xyz, instance.normal2.xyz);
}
fn meshInstanceFront(front: bool, orientation: f32) -> bool {
  let oriented = front == (orientation > 0.);
  if (mesh.viewport.z == 1. && !oriented) || (mesh.viewport.z == 2. && oriented) { discard; }
  return oriented;
}
''';

  static const wgsl = '''
struct MeshUniforms {
  mvp: mat4x4<f32>,
  normalMatrix: mat4x4<f32>,
  color: vec4<f32>,
  light: vec4<f32>,
  material: vec4<f32>,
  viewProjection: mat4x4<f32>,
  model: mat4x4<f32>,
  primitive: vec4<f32>,
  viewport: vec4<f32>,
};
@group(0) @binding(0) var<uniform> mesh: MeshUniforms;
fn meshColor(sample: vec4<f32>) -> vec4<f32> {
  let alpha = sample.a * mesh.material.y;
  let mode = mesh.material.w;
  if mode > .5 && mode < 1.5 && alpha < mesh.material.z { discard; }
  return vec4(sample.rgb * mesh.color.rgb, select(1., alpha, mode > 1.5));
}
''';
}

/// Advanced adapter contract for retained, validated mesh pipelines.
abstract interface class MeshShaderDevice
    implements ShaderDevice, ResourceDevice {
  Future<Object> compileMeshShader(MeshShaderDeviceDescription description);
  Future<void> releaseMeshShader(Object key);
}

final class MeshShaderDeviceDescription {
  final Map<String, Object?> data;
  MeshShaderDeviceDescription(this.data);
}

extension MeshShaderCompiler on ShaderCompiler {
  /// Compiles a mesh pipeline with engine uniforms in group zero. User bindings
  /// occupy groups one to three and may only read during the scene pass.
  Future<MeshShaderProgram> compileMesh(
    ShaderSource source, {
    ShaderBindings? bindings,
    MeshVertexLayout vertexLayout = MeshVertexLayout.positionNormal,
    MeshShaderGeometry geometry = MeshShaderGeometry.rigid,
    MeshSceneInputs sceneInputs = MeshSceneInputs.none,
    String vertexEntryPoint = 'vertex',
    String fragmentEntryPoint = 'fragment',
  }) => _run(() async {
    final device = _device;
    if (device is! MeshShaderDevice) {
      throw ShaderCompilationException(source, const [
        ShaderDiagnostic(
          message: 'This device cannot compile mesh shaders.',
          severity: ShaderDiagnosticSeverity.error,
        ),
      ], code: ShaderErrorCode.unsupportedFeature);
    }
    final values = bindings ?? ShaderBindings(const []);
    if (values.entries.any(
      (binding) =>
          binding.group == 0 ||
          binding._writes ||
          (geometry.usesDeformation && binding.group == 2) ||
          (sceneInputs != MeshSceneInputs.none && binding.group == 3),
    )) {
      throw GraphException(
        GraphErrorCode.invalidBinding,
        'Mesh bindings must be read-only. Group zero belongs to the engine; '
        'deformed programs reserve group two and scene inputs reserve group three.',
        passName: source.label,
      );
    }
    final encoded = _encodeShaderBindings(
      values,
      compute: false,
      label: source.label,
      use: (resource, read, write) {
        if (resource.isClosed || !identical(resource._scope._device, device)) {
          throw GraphException(
            resource.isClosed
                ? GraphErrorCode.closedResource
                : GraphErrorCode.foreignResource,
            'Mesh binding owner is closed or belongs to another device.',
            passName: source.label,
            resourceLabel: resource.label,
          );
        }
      },
    );
    final build = await device.compileShader(source);
    try {
      for (final (name, stage) in [
        (vertexEntryPoint, ShaderStage.vertex),
        (fragmentEntryPoint, ShaderStage.fragment),
      ]) {
        if (!build.entryPoints.any(
          (entry) => entry.name == name && entry.stage == stage,
        )) {
          throw GraphException(
            GraphErrorCode.invalidDescriptor,
            'Shader has no ${stage.name} entry point named $name.',
            passName: source.label,
          );
        }
      }
      final key = await device.compileMeshShader(
        MeshShaderDeviceDescription({
          'label': source.label,
          'program': build.key,
          'bindings': encoded,
          'vertexLayout': vertexLayout.index,
          'geometry': geometry.index,
          if (sceneInputs != MeshSceneInputs.none)
            'sceneInputs': sceneInputs.index,
          'vertexEntryPoint': vertexEntryPoint,
          'fragmentEntryPoint': fragmentEntryPoint,
        }),
      );
      final program = MeshShaderProgram._(
        this,
        device,
        key,
        source.label,
        vertexLayout,
        geometry,
        sceneInputs,
      );
      _meshes.add(program);
      _checkOpen();
      return program;
    } finally {
      await device.releaseShader(build.key);
    }
  });
}

/// A device-bound mesh program. Native ownership retains its module and bindings
/// independently of author scopes until accepted frames finish and it closes.
sealed class MeshProgram {
  MeshShaderGeometry get geometry;
  MeshSceneInputs get sceneInputs;
}

final class MeshShaderProgram implements MeshProgram {
  final ShaderCompiler _compiler;
  final MeshShaderDevice _device;
  final Object _key;
  final String label;
  final MeshVertexLayout vertexLayout;
  @override
  final MeshShaderGeometry geometry;
  @override
  final MeshSceneInputs sceneInputs;
  final _pending = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;
  MeshShaderProgram._(
    this._compiler,
    this._device,
    this._key,
    this.label,
    this.vertexLayout,
    this.geometry,
    this.sceneInputs,
  );
  bool get isClosed => _closed || _compiler.isClosed;

  /// Native adapter hook. The opaque key is only valid on this device, and its
  /// native ownership lasts until the returned frame future settles.
  Future<T> submitFrame<T>(
    ShaderDevice device,
    Future<T> Function(Object key) submit,
  ) {
    if (isClosed) {
      return Future.error(StateError('Mesh shader has closed: $label'));
    }
    final completion = Completer<T>();
    final result = completion.future;
    late Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    Future.sync(() {
      if (!identical(_device, device)) {
        throw GraphException(
          GraphErrorCode.foreignResource,
          'Mesh shader belongs to another device.',
          passName: label,
        );
      }
      return submit(_key);
    }).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await Future.wait(_pending);
    await _device.releaseMeshShader(_key);
  }
}
