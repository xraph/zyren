import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'gaussian.dart';
import 'projection.dart';

/// Native scene Gaussians with depth testing, clipping and premultiplied blend.
/// Mean-depth ordering estimates appearance; it does not reconstruct a surface.
final class GaussianSplatPlugin extends ScenePlugin {
  GaussianCloudData _data;
  final Group object;
  final String instanceId;
  final SplatLimits limits;
  final int capacity;
  final double minimumPixelVariance;
  GpuScope? _scope;
  GpuResource<Buffer>? _buffer;
  Mesh? _mesh;
  void Function()? _invalidate;
  List<ProjectedGaussian> _projected = const [];
  bool _enabled = true;
  int _dataRevision = 0;
  int get dataRevision => _dataRevision;
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _dataRevision++;
    _invalidate?.call();
  }

  AttachmentScope _lifetime = AttachmentScope();
  GaussianSplatPlugin({
    required GaussianCloudData data,
    this.instanceId = 'default',
    Group? object,
    this.limits = const SplatLimits(),
    int? capacity,
    this.minimumPixelVariance = .25,
  }) : _data = data,
       object = object ?? Group(name: 'Gaussian scene'),
       capacity = capacity ?? data.splats.length {
    if (!minimumPixelVariance.isFinite || minimumPixelVariance < 0) {
      throw ArgumentError('Invalid pixel variance floor.');
    }
    limits.validate();
    limits.checkCount(this.capacity);
    if (this.capacity < data.splats.length) {
      throw ArgumentError('Gaussian capacity is below its source count.');
    }
  }
  @override
  String get id => 'zyren.splats.scene.$instanceId';
  GaussianCloudData get data => _data;
  set data(GaussianCloudData value) {
    limits.checkCount(value.splats.length);
    if (value.splats.length > capacity) {
      throw StateError('Gaussian source exceeds scene capacity.');
    }
    _data = value;
    _dataRevision++;
    _invalidate?.call();
  }

  List<ProjectedGaussian> get projected => _projected;
  int get gpuPayloadBytes => capacity * (64 + 4 * 24 + 6 * 4);
  Registration onClose(void Function() callback) => _lifetime.onClose(callback);
  @override
  Future<void> attach(PluginContext context) async {
    if (_lifetime.isClosed) _lifetime = AttachmentScope();
    _invalidate = context.invalidate;
    final scope = context.createGpuScope(label: 'Gaussian scene $instanceId');
    _scope = scope;
    final buffer = await scope.resources.createBuffer(
      BufferDescriptor(
        label: 'projected Gaussians',
        size: capacity * 64,
        usage: {BufferUsage.storage, BufferUsage.copyDestination},
      ),
    );
    _buffer = buffer;
    final program = await scope.shaders.compile(
      ShaderSource.wgsl(_sceneWgsl, label: 'scene Gaussians'),
    );
    final shader = await scope.materials.compile(
      MeshShaderDescriptor(
        program: program,
        bindings: ShaderBindings([
          BufferBinding.storageRead(0, buffer, group: 1),
        ]),
        supportsClipping: true,
        blend: RenderBlend.premultipliedAlpha,
      ),
    );
    final positions = Float32List(capacity * 12),
        normals = Float32List(capacity * 12),
        indices = Uint32List(capacity * 6);
    for (var i = 0; i < capacity; i++) {
      for (var v = 0; v < 4; v++) {
        normals[(i * 4 + v) * 3 + 2] = 1;
      }
      indices.setRange(i * 6, i * 6 + 6, [
        i * 4,
        i * 4 + 1,
        i * 4 + 2,
        i * 4 + 2,
        i * 4 + 1,
        i * 4 + 3,
      ]);
    }
    final geometry = BufferGeometry.fromAttributes(
      attributes: {
        VertexSemantic.position: VertexAttribute(
          positions,
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          normals,
          format: VertexFormat.float32x3,
        ),
      },
      indices: indices,
    );
    final mesh = Mesh(
      geometry,
      ShaderMaterial(
        shader,
        side: MaterialSide.doubleSided,
        alphaMode: MaterialAlphaMode.blend,
        depthTest: true,
        depthWrite: DepthWrite.disabled,
      ),
      name: 'Gaussian appearance',
    )..outlineEnabled = false;
    _mesh = mesh;
    object.add(mesh);
    context.scene.add(object);
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    _mesh!.visible = enabled;
    if (!enabled) {
      _projected = const [];
      return;
    }
    final size = PhysicalSize(frame.width, frame.height);
    _projected = projectGaussians(
      _data,
      camera: context.camera,
      size: size,
      transform: object.worldMatrix,
      minimumPixelVariance: minimumPixelVariance,
    );
    final values = Float32List(capacity * 16);
    for (var i = 0; i < _projected.length; i++) {
      final p = _projected[i], offset = i * 16;
      values.setRange(offset, offset + 16, [
        p.center.x,
        p.center.y,
        p.center.z,
        p.source.opacity,
        p.extentX * 2 / size.width,
        p.extentY * 2 / size.height,
        p.extentX,
        p.extentY,
        p.yy / p.determinant,
        p.xy / p.determinant,
        p.xx / p.determinant,
        0,
        p.source.color.r,
        p.source.color.g,
        p.source.color.b,
        0,
      ]);
    }
    if (values.any((v) => !v.isFinite)) {
      throw StateError('Projected Gaussians exceed float32 capacity.');
    }
    await _scope!.resources.writeBuffer(_buffer!, values);
  }

  @override
  Future<void> detach(PluginContext context) async {
    _invalidate = null;
    _lifetime.close();
    if (_mesh case final mesh?) {
      object.remove(mesh);
    }
    _mesh = null;
    object.parent?.remove(object);
    await _scope?.close();
    _scope = null;
    _buffer = null;
    _projected = const [];
  }
}

final _sceneWgsl = '''${ShaderMaterial.uniformsWgsl}
struct Gaussian { center: vec4<f32>, extent: vec4<f32>, inverse: vec4<f32>, color: vec4<f32> };
@group(1) @binding(0) var<storage, read> gaussians: array<Gaussian>;
struct Vertex {
 @builtin(position) position: vec4<f32>, @location(0) delta: vec2<f32>,
 @location(1) relative: vec3<f32>, @location(2) @interpolate(flat) ordinal: u32,
};
@vertex fn vertex(@builtin(vertex_index) index: u32,
 @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> Vertex {
 let ordinal=index/4u; let p=gaussians[ordinal]; let corner=index%4u;
 let c=vec2<f32>(select(-1.,1.,(corner&1u)==1u),select(-1.,1.,corner>=2u));
 let ndc=p.center.xy+c*p.extent.xy;
 var output: Vertex;
 output.position=vec4<f32>(ndc,p.center.z,1.);
 if p.center.w==0. {output.position=vec4<f32>(2.,2.,2.,1.);}
 output.delta=c*p.extent.zw;output.ordinal=ordinal;
 let relative=mesh.inverse_view_projection*vec4<f32>(ndc,p.center.z,1.);
 output.relative=relative.xyz/relative.w;
 return output;
}
@fragment fn fragment(input: Vertex) -> @location(0) vec4<f32> {
 meshClip(input.relative);
 let p=gaussians[input.ordinal];let d=input.delta;
 let q=p.inverse.x*d.x*d.x-2.*p.inverse.y*d.x*d.y+p.inverse.z*d.y*d.y;
 if q>9. {discard;}
 let color=meshColor(vec4<f32>(p.color.xyz,p.center.w*exp(-.5*q)));
 return vec4<f32>(color.rgb*color.a,color.a);
}
''';
