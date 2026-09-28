import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'effects.dart' show UnsupportedEffects;

/// Applies a UV stripe material to a borrowed mesh for this attachment's lifetime.
final class PatternMaterialPlugin extends ScenePlugin {
  final Mesh mesh;
  final UnsupportedEffects unsupported;
  double _frequency;
  double? _uploaded;
  PluginContext? _context;
  MeshMaterial? _original;
  ShaderMaterial? _material;
  GpuResource<Buffer>? _parameters;
  @override
  final String id;
  PatternMaterialPlugin(
    this.mesh, {
    double frequency = 8,
    this.unsupported = UnsupportedEffects.reject,
    this.id = 'shader-lab.pattern',
  }) : _frequency = _valid(frequency);

  static double _valid(double value) {
    if (!value.isFinite || value < 1 || value > 16) {
      throw ArgumentError.value(value, 'frequency', 'Expected [1, 16].');
    }
    return value;
  }

  double get frequency => _frequency;
  set frequency(double value) {
    _frequency = _valid(value);
    final context = _context;
    if (context != null && !context.scope.isClosed) context.invalidate();
  }

  static const features = {
    RenderFeature.meshShaders,
    RenderFeature.shaderCompilation,
    RenderFeature.scopedResources,
  };
  @override
  Set<RenderFeature> get requiredFeatures =>
      unsupported == UnsupportedEffects.reject ? features : const {};

  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    if (!context.capabilities.features.containsAll(features)) return;
    final original = mesh.material;
    final deformed = mesh.captureDeformation() != null;
    final geometry = mesh is InstancedMesh
        ? (deformed
              ? MeshShaderGeometry.deformedInstanced
              : MeshShaderGeometry.instanced)
        : (deformed ? MeshShaderGeometry.deformed : MeshShaderGeometry.rigid);
    _parameters = await context.resources.createBuffer(
      BufferDescriptor(
        label: 'stripe frequency',
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    final program = await context.shaders.compileMesh(
      ShaderSource.wgsl(_patternWgsl(geometry), label: '$id.wgsl'),
      geometry: geometry,
      vertexLayout: MeshVertexLayout.positionNormalUv,
      bindings: ShaderBindings([
        BufferBinding.uniform(0, _parameters!, group: 1),
      ]),
    );
    _material = ShaderMaterial(
      program,
      color: original.color,
      side: original.side,
      alphaMode: original.alphaMode,
      opacity: original.opacity,
      alphaCutoff: original.alphaCutoff,
      depthTest: original.depthTest,
      depthWrite: original.depthWrite,
    );
    _original = original;
    mesh.material = _material!;
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    if (_parameters == null || _uploaded == _frequency) return;
    final frequency = _frequency;
    await context.resources.writeBuffer(
      _parameters!,
      Float32List.fromList([frequency, 0, 0, 0]),
    );
    _uploaded = frequency;
  }

  @override
  void detach(PluginContext context) {
    if (_original != null && identical(mesh.material, _material)) {
      mesh.material = _original!;
    }
    _context = null;
    _original = null;
    _material = null;
    _parameters = null;
    _uploaded = null;
  }
}

String _patternWgsl(MeshShaderGeometry geometry) =>
    '''
${MeshShaderInterface.wgsl}
${geometry.usesInstancing ? MeshShaderInterface.instancing : ''}
${geometry.usesDeformation ? MeshShaderInterface.deformation : ''}
@group(1) @binding(0) var<uniform> pattern: vec4<f32>;
struct Vertex {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
  @location(1) normal: vec3<f32>,
  @location(2) @interpolate(flat) orientation: f32,
};
@vertex fn vertex(@builtin(vertex_index) index: u32, @location(0) p: vec3<f32>, @location(1) n: vec3<f32>,
    @location(2) uv: vec2<f32> ${geometry.usesInstancing ? ', instance: MeshInstanceInput' : ''}) -> Vertex {
  var position = p; var normal = n;
  ${geometry.usesDeformation ? '''let d = deform_vertex(index, p, n, vec4(1.,0.,0.,1.));
  position = d.position; normal = d.normal;''' : ''}
  ${geometry.usesInstancing ? '''position = (meshInstanceMatrix(instance) * vec4(position,1.)).xyz;
  normal = meshInstanceNormalMatrix(instance) * normal;''' : ''}
  return Vertex(mesh.mvp * vec4(position, 1.), uv, (mesh.normalMatrix * vec4(normal, 0.)).xyz,
    ${geometry.usesInstancing ? 'instance.normal0.w' : '1.'});
}
@fragment fn fragment(input: Vertex, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
  ${geometry.usesInstancing ? 'let facing = meshInstanceFront(front, input.orientation);' : ''}
  let phase = (input.uv.x + input.uv.y) * pattern.x;
  let stripe = .5 + .5 * sin(phase * 6.2831853);
  let feather = min(.45, fwidth(phase));
  let tone = mix(.08, 1., smoothstep(.5 - feather, .5 + feather, stripe));
  let light = mesh.light.w + (1. - mesh.light.w) * max(0., dot(normalize(input.normal), normalize(mesh.light.xyz)));
  return meshColor(vec4(vec3(tone * light), 1.));
}
''';
