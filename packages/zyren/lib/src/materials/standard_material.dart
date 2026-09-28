part of 'material.dart';

/// Isotropic metallic/roughness shading. Emission is linear radiance.
final class StandardMaterial extends MeshMaterial {
  final double metallic, roughness, emissiveIntensity;
  final Color3 emissive;
  Color3 get baseColor => color;
  StandardMaterial({
    Color3 baseColor = const Color3(1, 1, 1),
    this.metallic = 0,
    this.roughness = 1,
    this.emissive = const Color3(0, 0, 0),
    this.emissiveIntensity = 1,
    super.colorMap,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  }) : super(color: baseColor) {
    emissive.toList();
    if (!metallic.isFinite ||
        metallic < 0 ||
        metallic > 1 ||
        !roughness.isFinite ||
        roughness < 0 ||
        roughness > 1 ||
        !emissiveIntensity.isFinite ||
        emissiveIntensity < 0 ||
        emissiveIntensity > 65504) {
      throw ArgumentError('Invalid standard material factors.');
    }
  }
  @override
  bool get unlit => false;
  StandardMaterial copyWith({
    Color3? color,
    double? metallic,
    double? roughness,
    Color3? emissive,
    double? emissiveIntensity,
    TextureMap? colorMap,
    MaterialSide? side,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => StandardMaterial(
    baseColor: color ?? this.color,
    metallic: metallic ?? this.metallic,
    roughness: roughness ?? this.roughness,
    emissive: emissive ?? this.emissive,
    emissiveIntensity: emissiveIntensity ?? this.emissiveIntensity,
    colorMap: colorMap ?? this.colorMap,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
