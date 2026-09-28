part of 'material.dart';

/// Isotropic metallic/roughness shading. Emission is linear radiance.
final class StandardMaterial extends MeshMaterial {
  final double metallic, roughness, emissiveIntensity;
  final Color3 emissive;
  final TextureMap? normalMap, metallicRoughnessMap, occlusionMap, emissiveMap;
  final double normalScaleX, normalScaleY, occlusionStrength;
  Color3 get baseColor => color;
  StandardMaterial({
    Color3 baseColor = const Color3(1, 1, 1),
    this.metallic = 0,
    this.roughness = 1,
    this.emissive = const Color3(0, 0, 0),
    this.emissiveIntensity = 1,
    super.colorMap,
    this.normalMap,
    this.metallicRoughnessMap,
    this.occlusionMap,
    this.emissiveMap,
    this.normalScaleX = 1,
    this.normalScaleY = 1,
    this.occlusionStrength = 1,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  }) : super(color: baseColor) {
    emissive.toList();
    for (final map in [normalMap, metallicRoughnessMap, occlusionMap]) {
      if (map != null &&
          map.image.descriptor.format != TextureFormat.rgba8Unorm) {
        throw ArgumentError(
          'Normal and scalar maps require linear RGBA8 storage.',
        );
      }
    }
    if (!normalScaleX.isFinite ||
        !normalScaleY.isFinite ||
        normalScaleX.abs() > 1e6 ||
        normalScaleY.abs() > 1e6 ||
        !occlusionStrength.isFinite ||
        occlusionStrength < 0 ||
        occlusionStrength > 1) {
      throw ArgumentError('Invalid normal scale or occlusion strength.');
    }
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
    normalMap,
    metallicRoughnessMap,
    occlusionMap,
    emissiveMap,
    double? normalScaleX,
    normalScaleY,
    occlusionStrength,
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
    normalMap: normalMap ?? this.normalMap,
    metallicRoughnessMap: metallicRoughnessMap ?? this.metallicRoughnessMap,
    occlusionMap: occlusionMap ?? this.occlusionMap,
    emissiveMap: emissiveMap ?? this.emissiveMap,
    normalScaleX: normalScaleX ?? this.normalScaleX,
    normalScaleY: normalScaleY ?? this.normalScaleY,
    occlusionStrength: occlusionStrength ?? this.occlusionStrength,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
