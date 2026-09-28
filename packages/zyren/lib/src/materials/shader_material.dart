part of 'material.dart';

/// A scoped WGSL material with the standard mesh transform and render state.
final class ShaderMaterial extends MeshMaterial {
  /// Native mesh uniform layout. Model positions are relative to camera origin.
  /// [meshColor] applies color, opacity and alpha mode to a fragment's result.
  static const uniformsWgsl = '''
struct MeshUniforms {
  mvp: mat4x4<f32>, normal_matrix: mat4x4<f32>,
  color_unlit: vec4<f32>, light_ambient: vec4<f32>, map_params: vec4<f32>,
  view_projection: mat4x4<f32>, model: mat4x4<f32>,
  primitive: vec4<f32>, viewport: vec4<f32>,
};
@group(0) @binding(0) var<uniform> mesh: MeshUniforms;
struct MeshVertex {
  @builtin(position) position: vec4<f32>,
  @location(0) normal: vec3<f32>,
  @location(1) uv0: vec2<f32>, @location(2) uv1: vec2<f32>,
  @location(3) relativePosition: vec3<f32>,
};
fn meshColor(color: vec4<f32>) -> vec4<f32> {
  let alpha = color.a * mesh.map_params.y;
  let mode = mesh.map_params.w;
  if mode > 0.5 && mode < 1.5 && alpha < mesh.map_params.z { discard; }
  return vec4(color.rgb * mesh.color_unlit.rgb, select(1., alpha, mode > 1.5));
}
''';

  /// Standard transform entry point. Set MeshShaderDescriptor.requiresUv when
  /// requesting UV inputs; absent secondary UVs use the geometry's zero channel.
  static String vertexWgsl({bool uv = false}) =>
      '''
@vertex fn vertex(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>
${uv ? ', @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>' : ''}) -> MeshVertex {
  var output: MeshVertex;
  output.position = mesh.mvp * vec4(position, 1.);
  output.normal = (mesh.normal_matrix * vec4(normal, 0.)).xyz;
  output.relativePosition = (mesh.model * vec4(position, 1.)).xyz;
  output.uv0 = ${uv ? 'uv0' : 'vec2<f32>(0.)'};
  output.uv1 = ${uv ? 'uv1' : 'vec2<f32>(0.)'};
  return output;
}
''';

  final MeshShader shader;
  ShaderMaterial(
    this.shader, {
    Color3 color = const Color3(1, 1, 1),
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  }) : super(color: color) {
    if (shader.descriptor is PostProcessDescriptor) {
      throw ArgumentError('A fullscreen effect cannot be used on a mesh.');
    }
  }
  @override
  bool get unlit => true;
  ShaderMaterial copyWith({
    Color3? color,
    MaterialSide? side,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => ShaderMaterial(
    shader,
    color: color ?? this.color,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
