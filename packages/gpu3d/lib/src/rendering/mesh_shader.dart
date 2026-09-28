part of '../resources/resource_scope.dart';

enum MeshVertexLayout { positionNormal, positionNormalUv }

/// Include this prelude in WGSL to use the scene's group-zero uniform layout.
/// Matrices use camera-relative world coordinates. Fragment output is linear.
abstract final class MeshShaderInterface {
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
      (binding) => binding.group == 0 || binding._writes,
    )) {
      throw GraphException(
        GraphErrorCode.invalidBinding,
        'Mesh bindings must be read-only and use groups one to three.',
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
final class MeshShaderProgram {
  final ShaderCompiler _compiler;
  final MeshShaderDevice _device;
  final Object _key;
  final String label;
  final MeshVertexLayout vertexLayout;
  final _pending = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;
  MeshShaderProgram._(
    this._compiler,
    this._device,
    this._key,
    this.label,
    this.vertexLayout,
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
