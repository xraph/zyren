part of 'material.dart';

/// Layered GGX reflectance with dielectric, coat, cloth and brushed surfaces.
/// Colors and lighting operate in linear space. Rotation is in radians about
/// the surface normal. Anisotropy uses the geometry's tangent frame.
final class PhysicalMaterial extends StandardMaterial {
  /// Thin-film thickness is measured in nanometres. Dispersion controls the
  /// wavelength spread through a transmissive volume; zero disables it.
  final double iridescence, iridescenceIor;
  final double iridescenceThicknessMinimum, iridescenceThicknessMaximum;
  final double dispersion;
  final TextureMap? iridescenceMap, iridescenceThicknessMap;

  /// Optical transmission, independent of alpha coverage.
  final double transmission, thickness, attenuationDistance;
  final Color3 attenuationColor;
  final double clearcoatNormalScale;
  final TextureMap? clearcoatMap,
      clearcoatRoughnessMap,
      clearcoatNormalMap,
      sheenColorMap,
      sheenRoughnessMap,
      specularIntensityMap,
      specularColorMap,
      anisotropyMap,
      transmissionMap,
      thicknessMap;
  @override
  Iterable<TextureMap> get textureMaps => [
    ...super.textureMaps,
    ?clearcoatMap,
    ?clearcoatRoughnessMap,
    ?clearcoatNormalMap,
    ?sheenColorMap,
    ?sheenRoughnessMap,
    ?specularIntensityMap,
    ?specularColorMap,
    ?anisotropyMap,
    ?transmissionMap,
    ?thicknessMap,
    ?iridescenceMap,
    ?iridescenceThicknessMap,
  ];

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
    this.iridescence = 0,
    this.iridescenceIor = 1.3,
    this.iridescenceThicknessMinimum = 100,
    this.iridescenceThicknessMaximum = 400,
    this.dispersion = 0,
    this.iridescenceMap,
    this.iridescenceThicknessMap,
    this.transmission = 0,
    this.thickness = 0,
    this.attenuationDistance = double.infinity,
    this.attenuationColor = const Color3(1, 1, 1),
    this.transmissionMap,
    this.thicknessMap,
    this.clearcoatNormalScale = 1,
    this.clearcoatMap,
    this.clearcoatRoughnessMap,
    this.clearcoatNormalMap,
    this.sheenColorMap,
    this.sheenRoughnessMap,
    this.specularIntensityMap,
    this.specularColorMap,
    this.anisotropyMap,

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
    super.normalScaleX,
    super.normalScaleY,
    super.color,
    super.colorMap,
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
      'iridescence': iridescence,
      'transmission': transmission,
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
    for (final (value, lower, upper, name) in [
      (iridescenceIor, 1.0, 1e6, 'iridescenceIor'),
      (iridescenceThicknessMinimum, 0.0, 1e6, 'iridescenceThicknessMinimum'),
      (iridescenceThicknessMaximum, 0.0, 1e6, 'iridescenceThicknessMaximum'),
      (dispersion, 0.0, 1e3, 'dispersion'),
    ]) {
      if (!value.isFinite || value < lower || value > upper) {
        throw ArgumentError.value(value, name, 'Expected [$lower, $upper].');
      }
    }
    if (!thickness.isFinite || thickness < 0 || thickness > 1e6) {
      throw ArgumentError.value(thickness, 'thickness', 'Expected [0, 1e6].');
    }
    if (attenuationDistance.isNaN ||
        attenuationDistance <= 0 ||
        (attenuationDistance.isFinite &&
            (attenuationDistance < 1e-6 || attenuationDistance > 1e12))) {
      throw ArgumentError.value(
        attenuationDistance,
        'attenuationDistance',
        'Expected [1e-6, 1e12] or infinity.',
      );
    }
    attenuationColor.toList();
    if (!ior.isFinite || (ior != 0 && ior < 1) || ior > 1e6) {
      throw ArgumentError.value(ior, 'ior', 'Expected zero or [1, 1e6].');
    }
    if (!anisotropyRotation.isFinite || anisotropyRotation.abs() > 1e6) {
      throw ArgumentError.value(
        anisotropyRotation,
        'anisotropyRotation',
        'Expected finite radians in [-1e6, 1e6].',
      );
    }
    if (!clearcoatNormalScale.isFinite || clearcoatNormalScale.abs() > 1e6) {
      throw ArgumentError.value(clearcoatNormalScale, 'clearcoatNormalScale');
    }
    for (final map in [
      clearcoatMap,
      clearcoatRoughnessMap,
      clearcoatNormalMap,
      sheenRoughnessMap,
      specularIntensityMap,
      anisotropyMap,
      transmissionMap,
      thicknessMap,
      iridescenceMap,
      iridescenceThicknessMap,
    ].nonNulls) {
      if (map.image.descriptor.format.isSrgb) {
        throw ArgumentError(
          'Physical data maps require a linear texture format.',
        );
      }
    }
    specularColor.toList(maxChannel: 1e6);
    sheenColor.toList();
  }
  @override
  PhysicalMaterial copyWith({
    double? iridescence,
    double? iridescenceIor,
    double? iridescenceThicknessMinimum,
    double? iridescenceThicknessMaximum,
    double? dispersion,
    TextureMap? iridescenceMap,
    TextureMap? iridescenceThicknessMap,
    bool clearIridescenceMap = false,
    bool clearIridescenceThicknessMap = false,
    double? transmission,
    double? thickness,
    double? attenuationDistance,
    Color3? attenuationColor,
    TextureMap? transmissionMap,
    TextureMap? thicknessMap,
    bool clearTransmissionMap = false,
    bool clearThicknessMap = false,
    double? clearcoatNormalScale,
    TextureMap? clearcoatMap,
    bool clearClearcoatMap = false,
    TextureMap? clearcoatRoughnessMap,
    bool clearClearcoatRoughnessMap = false,
    TextureMap? clearcoatNormalMap,
    bool clearClearcoatNormalMap = false,
    TextureMap? sheenColorMap,
    bool clearSheenColorMap = false,
    TextureMap? sheenRoughnessMap,
    bool clearSheenRoughnessMap = false,
    TextureMap? specularIntensityMap,
    bool clearSpecularIntensityMap = false,
    TextureMap? specularColorMap,
    bool clearSpecularColorMap = false,
    TextureMap? anisotropyMap,
    bool clearAnisotropyMap = false,

    double? ior,
    double? specularIntensity,
    double? clearcoat,
    double? clearcoatRoughness,
    double? sheenRoughness,
    double? anisotropy,
    double? anisotropyRotation,
    Color3? specularColor,
    Color3? sheenColor,
    Color3? color,
    TextureMap? colorMap,
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
    double? normalScaleX,
    double? normalScaleY,
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
    iridescence: iridescence ?? this.iridescence,
    iridescenceIor: iridescenceIor ?? this.iridescenceIor,
    iridescenceThicknessMinimum:
        iridescenceThicknessMinimum ?? this.iridescenceThicknessMinimum,
    iridescenceThicknessMaximum:
        iridescenceThicknessMaximum ?? this.iridescenceThicknessMaximum,
    dispersion: dispersion ?? this.dispersion,
    iridescenceMap: clearIridescenceMap
        ? null
        : iridescenceMap ?? this.iridescenceMap,
    iridescenceThicknessMap: clearIridescenceThicknessMap
        ? null
        : iridescenceThicknessMap ?? this.iridescenceThicknessMap,
    transmission: transmission ?? this.transmission,
    thickness: thickness ?? this.thickness,
    attenuationDistance: attenuationDistance ?? this.attenuationDistance,
    attenuationColor: attenuationColor ?? this.attenuationColor,
    transmissionMap: clearTransmissionMap
        ? null
        : transmissionMap ?? this.transmissionMap,
    thicknessMap: clearThicknessMap ? null : thicknessMap ?? this.thicknessMap,
    clearcoatNormalScale: clearcoatNormalScale ?? this.clearcoatNormalScale,
    clearcoatMap: clearClearcoatMap ? null : clearcoatMap ?? this.clearcoatMap,
    clearcoatRoughnessMap: clearClearcoatRoughnessMap
        ? null
        : clearcoatRoughnessMap ?? this.clearcoatRoughnessMap,
    clearcoatNormalMap: clearClearcoatNormalMap
        ? null
        : clearcoatNormalMap ?? this.clearcoatNormalMap,
    sheenColorMap: clearSheenColorMap
        ? null
        : sheenColorMap ?? this.sheenColorMap,
    sheenRoughnessMap: clearSheenRoughnessMap
        ? null
        : sheenRoughnessMap ?? this.sheenRoughnessMap,
    specularIntensityMap: clearSpecularIntensityMap
        ? null
        : specularIntensityMap ?? this.specularIntensityMap,
    specularColorMap: clearSpecularColorMap
        ? null
        : specularColorMap ?? this.specularColorMap,
    anisotropyMap: clearAnisotropyMap
        ? null
        : anisotropyMap ?? this.anisotropyMap,

    ior: ior ?? this.ior,
    specularIntensity: specularIntensity ?? this.specularIntensity,
    clearcoat: clearcoat ?? this.clearcoat,
    clearcoatRoughness: clearcoatRoughness ?? this.clearcoatRoughness,
    sheenRoughness: sheenRoughness ?? this.sheenRoughness,
    anisotropy: anisotropy ?? this.anisotropy,
    anisotropyRotation: anisotropyRotation ?? this.anisotropyRotation,
    specularColor: specularColor ?? this.specularColor,
    sheenColor: sheenColor ?? this.sheenColor,
    baseColor: color ?? baseColor ?? this.baseColor,
    baseColorMap: clearBaseColorMap
        ? null
        : colorMap ?? baseColorMap ?? this.baseColorMap,
    normalMap: clearNormalMap ? null : normalMap ?? this.normalMap,
    metallicRoughnessMap: clearMetallicRoughnessMap
        ? null
        : metallicRoughnessMap ?? this.metallicRoughnessMap,
    occlusionMap: clearOcclusionMap ? null : occlusionMap ?? this.occlusionMap,
    emissiveMap: clearEmissiveMap ? null : emissiveMap ?? this.emissiveMap,
    normalScale: normalScale ?? this.normalScale,
    normalScaleX: normalScaleX ?? normalScale ?? this.normalScaleX,
    normalScaleY: normalScaleY ?? normalScale ?? this.normalScaleY,
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
