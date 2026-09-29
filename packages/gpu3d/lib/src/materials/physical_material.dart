part of 'material.dart';

/// Layered GGX reflectance with dielectric, coat, cloth and brushed surfaces.
/// Colors and lighting operate in linear space. Rotation is in radians about
/// the surface normal. Anisotropy uses the geometry's tangent frame.
final class PhysicalMaterial extends StandardMaterial {
  final double ior;
  final double specularIntensity;
  final double clearcoat;
  final double clearcoatRoughness;
  final double sheenRoughness;
  final double anisotropy;
  final double anisotropyRotation;
  final Color3 specularColor;
  final Color3 sheenColor;
  PhysicalMaterial({
    this.ior = 1.5,
    this.specularIntensity = 1,
    this.clearcoat = 0,
    this.clearcoatRoughness = 0,
    this.sheenRoughness = 1,
    this.anisotropy = 0,
    this.anisotropyRotation = 0,
    this.specularColor = const Color3(1, 1, 1),
    this.sheenColor = const Color3(0, 0, 0),
    super.baseColor,
    super.baseColorMap,
    super.normalMap,
    super.metallicRoughnessMap,
    super.occlusionMap,
    super.emissiveMap,
    super.normalScale,
    super.occlusionStrength,
    super.metallic,
    super.roughness,
    super.emissive,
    super.emissiveIntensity,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.vertexColors,
    super.depthWrite,
  }) {
    for (final entry in {
      'specularIntensity': specularIntensity,
      'clearcoat': clearcoat,
      'clearcoatRoughness': clearcoatRoughness,
      'sheenRoughness': sheenRoughness,
      'anisotropy': anisotropy,
    }.entries) {
      if (!entry.value.isFinite || entry.value < 0 || entry.value > 1) {
        throw ArgumentError.value(entry.value, entry.key, 'Expected [0, 1].');
      }
    }
    if (!ior.isFinite || ior < 1 || ior > 10) {
      throw ArgumentError.value(ior, 'ior', 'Expected [1, 10].');
    }
    if (!anisotropyRotation.isFinite || anisotropyRotation.abs() > 1e6) {
      throw ArgumentError.value(
        anisotropyRotation,
        'anisotropyRotation',
        'Expected finite radians in [-1e6, 1e6].',
      );
    }
    specularColor.toList();
    sheenColor.toList();
  }
  @override
  PhysicalMaterial copyWith({
    double? ior,
    double? specularIntensity,
    double? clearcoat,
    double? clearcoatRoughness,
    double? sheenRoughness,
    double? anisotropy,
    double? anisotropyRotation,
    Color3? specularColor,
    Color3? sheenColor,
    Color3? baseColor,
    TextureMap? baseColorMap,
    bool clearBaseColorMap = false,
    TextureMap? normalMap,
    TextureMap? metallicRoughnessMap,
    TextureMap? occlusionMap,
    TextureMap? emissiveMap,
    bool clearNormalMap = false,
    bool clearMetallicRoughnessMap = false,
    bool clearOcclusionMap = false,
    bool clearEmissiveMap = false,
    double? normalScale,
    double? occlusionStrength,
    double? metallic,
    double? roughness,
    Color3? emissive,
    double? emissiveIntensity,
    MaterialSide? side,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    bool? vertexColors,
    DepthWrite? depthWrite,
  }) => PhysicalMaterial(
    ior: ior ?? this.ior,
    specularIntensity: specularIntensity ?? this.specularIntensity,
    clearcoat: clearcoat ?? this.clearcoat,
    clearcoatRoughness: clearcoatRoughness ?? this.clearcoatRoughness,
    sheenRoughness: sheenRoughness ?? this.sheenRoughness,
    anisotropy: anisotropy ?? this.anisotropy,
    anisotropyRotation: anisotropyRotation ?? this.anisotropyRotation,
    specularColor: specularColor ?? this.specularColor,
    sheenColor: sheenColor ?? this.sheenColor,
    baseColor: baseColor ?? this.baseColor,
    baseColorMap: clearBaseColorMap ? null : baseColorMap ?? this.baseColorMap,
    normalMap: clearNormalMap ? null : normalMap ?? this.normalMap,
    metallicRoughnessMap: clearMetallicRoughnessMap
        ? null
        : metallicRoughnessMap ?? this.metallicRoughnessMap,
    occlusionMap: clearOcclusionMap ? null : occlusionMap ?? this.occlusionMap,
    emissiveMap: clearEmissiveMap ? null : emissiveMap ?? this.emissiveMap,
    normalScale: normalScale ?? this.normalScale,
    occlusionStrength: occlusionStrength ?? this.occlusionStrength,
    metallic: metallic ?? this.metallic,
    roughness: roughness ?? this.roughness,
    emissive: emissive ?? this.emissive,
    emissiveIntensity: emissiveIntensity ?? this.emissiveIntensity,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    vertexColors: vertexColors ?? this.vertexColors,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
