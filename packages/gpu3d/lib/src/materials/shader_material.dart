part of 'material.dart';

/// A custom WGSL mesh program. Its shader controls color and alpha output;
/// side, blending and depth settings control the native raster pipeline.
final class ShaderMaterial extends MeshMaterial {
  final MeshShaderProgram program;
  ShaderMaterial(
    this.program, {
    Color3? color,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  }) : super(color: color ?? const Color3(1, 1, 1));
  ShaderMaterial copyWith({
    MeshShaderProgram? program,
    Color3? color,
    MaterialSide? side,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => ShaderMaterial(
    program ?? this.program,
    color: color ?? this.color,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );

  @override
  bool get unlit => true;
}
