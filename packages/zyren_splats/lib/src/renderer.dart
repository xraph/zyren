import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'gaussian.dart';
import 'projection.dart';

/// Native offscreen orthographic Gaussians with CPU covariance projection/sorting.
/// Attach [object] for scene transforms and identity; call [render] explicitly.
/// This color-only pass does not render or depth-test other scene geometry.
final class GaussianSplatRenderer {
  final GaussianCloudData data;
  final SplatLimits limits;
  final Vec3 sourceOrigin;
  final Group object;
  final GpuScope _scope;
  final ShaderProgram _program;
  bool _closed = false;
  final AttachmentScope _lifetime = AttachmentScope();
  Future<ImageData>? _pending;
  Future<void>? _closing;
  GaussianSplatRenderer._(
    this.data,
    this.limits,
    this.sourceOrigin,
    this.object,
    this._scope,
    this._program,
  );

  static Future<GaussianSplatRenderer> create(
    GpuScope owner,
    GaussianCloudData data, {
    SplatLimits limits = const SplatLimits(),
  }) async {
    limits.validate();
    limits.checkCount(data.splats.length);
    final scope = owner.createChild(label: 'Gaussian splats');
    try {
      final shader = await scope.shaders.compile(
        ShaderSource.wgsl(_wgsl, label: 'orthographic Gaussians'),
      );
      final origin = data.splats.first.mean;
      return GaussianSplatRenderer._(
        data,
        limits,
        origin,
        Group(name: data.sourceUri.toString())..position = origin,
        scope,
        shader,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  bool get isClosed => _closed || _scope.isClosed;
  Registration onClose(void Function() callback) => _lifetime.onClose(callback);

  Future<ImageData> render({
    required OrthographicCamera camera,
    required PhysicalSize size,
  }) {
    if (isClosed) {
      return Future.error(StateError('Gaussian renderer has closed.'));
    }
    if (_pending != null) {
      return Future.error(StateError('Await the preceding Gaussian render.'));
    }
    if (size.width * size.height * 4 > limits.maxTargetBytes) {
      return Future.error(
        StateError('Gaussian target exceeds its byte budget.'),
      );
    }
    // Capture transforms and covariance before the first asynchronous operation.
    List<ProjectedGaussian> projected;
    try {
      var visible = true;
      for (Object3D? node = object; node != null; node = node.parent) {
        visible = visible && node.visible;
      }
      projected = visible
          ? projectGaussians(
              data,
              camera: camera,
              size: size,
              transform: object.worldMatrix,
              sourceOrigin: sourceOrigin,
            )
          : [];
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    late Future<ImageData> operation;
    operation = _render(projected, size).whenComplete(() {
      if (identical(_pending, operation)) _pending = null;
    });
    _pending = operation;
    return operation;
  }

  Future<ImageData> _render(
    List<ProjectedGaussian> projected,
    PhysicalSize size,
  ) async {
    final frame = _scope.createChild(label: 'Gaussian frame');
    try {
      final values = Float32List(
        (projected.isEmpty ? 1 : projected.length) * 16,
      );
      for (var i = 0; i < projected.length; i++) {
        final p = projected[i], offset = i * 16;
        values.setRange(offset, offset + 16, [
          p.center.x,
          p.center.y,
          p.extentX * 2 / size.width,
          p.extentY * 2 / size.height,
          p.yy / p.determinant,
          p.xy / p.determinant,
          p.xx / p.determinant,
          p.source.opacity,
          p.source.color.r,
          p.source.color.g,
          p.source.color.b,
          0,
          p.extentX,
          p.extentY,
          0,
          0,
        ]);
      }
      if (values.any((v) => !v.isFinite)) {
        throw ArgumentError('Projected values do not fit float32.');
      }
      final buffer = await frame.resources.createBuffer(
        BufferDescriptor(
          label: 'projected Gaussians',
          size: values.lengthInBytes,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      await frame.resources.writeBuffer(buffer, values);
      final target = await frame.resources.createTexture(
        TextureDescriptor(
          label: 'Gaussian color',
          width: size.width,
          height: size.height,
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
        ),
      );
      final graph = await frame.graphs.compile(
        GraphDescription(
          inputs: [buffer],
          passes: [
            RenderPassDescriptor(
              name: 'Gaussian alpha',
              program: _program,
              color: ColorAttachment(target),
              blend: RenderBlend.premultipliedAlpha,
              vertexCount: 6,
              instanceCount: projected.isEmpty ? 1 : projected.length,
              bindings: ShaderBindings([BufferBinding.storageRead(0, buffer)]),
              reads: [buffer],
              writes: [target],
            ),
          ],
        ),
      );
      await graph.execute();
      final pixels = await frame.resources.readTexture(target);
      return ImageData(
        pixels: pixels,
        size: size,
        colorSpace: ColorSpace.linear,
        alphaMode: AlphaMode.premultiplied,
      );
    } finally {
      await frame.close();
    }
  }

  Future<void> close() {
    _closed = true;
    _lifetime.close();
    object.parent?.remove(object);
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await _pending;
    } catch (_) {
      /* The render caller receives failures. */
    }
    await _scope.close();
  }
}

const _wgsl = '''
struct Gaussian { center: vec4<f32>, conic: vec4<f32>, color: vec4<f32>, extent: vec4<f32> };
@group(0) @binding(0) var<storage, read> gaussians: array<Gaussian>;
struct Vertex {
 @builtin(position) position: vec4<f32>, @location(0) offset: vec2<f32>,
 @location(1) @interpolate(flat) record: u32,
};
@vertex fn vertex(@builtin(vertex_index) vertex: u32, @builtin(instance_index) instance: u32) -> Vertex {
 let corners = array<vec2<f32>,6>(vec2(-1.,-1.),vec2(1.,-1.),vec2(-1.,1.),
   vec2(-1.,1.),vec2(1.,-1.),vec2(1.,1.));
 let g = gaussians[instance]; let corner = corners[vertex];
 var output: Vertex;
 output.position = vec4(g.center.xy + corner*g.center.zw, 0., 1.);
 output.offset = corner*g.extent.xy; output.record = instance;
 return output;
}
@fragment fn fragment(input: Vertex) -> @location(0) vec4<f32> {
 let g = gaussians[input.record]; let d = input.offset;
 let q = g.conic.x*d.x*d.x - 2.*g.conic.y*d.x*d.y + g.conic.z*d.y*d.y;
 if q > 9. { discard; }
 let alpha = g.conic.w*exp(-0.5*q);
 return vec4(g.color.rgb*alpha, alpha);
}
''';
