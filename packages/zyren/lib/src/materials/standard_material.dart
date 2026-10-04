part of 'material.dart';

/// Metallic/roughness material in linear light. Direct lighting uses explicit
/// scene lights; emission is independent of them.
base class StandardMaterial extends MeshMaterial {
  final bool localReflections;
  final double metallic, roughness, emissiveIntensity;
  final Color3 emissive;
  final TextureMap? normalMap, metallicRoughnessMap, occlusionMap, emissiveMap;
  final double normalScale, normalScaleY, occlusionStrength;

  /// Screen-space normal variance used to broaden specular highlights.
  /// Set this or [specularAntiAliasingThreshold] to zero to disable filtering.
  final double specularAntiAliasingVariance;

  /// Maximum variance added to alpha squared (perceptual roughness to power 4).
  final double specularAntiAliasingThreshold;
  double get normalScaleX => normalScale;
  @override
  Iterable<TextureMap> get textureMaps => [
    ...super.textureMaps,
    ?normalMap,
    ?metallicRoughnessMap,
    ?occlusionMap,
    ?emissiveMap,
  ];
  Color3 get baseColor => color;
  TextureMap? get baseColorMap => colorMap;
  StandardMaterial({
    Color3 baseColor = const Color3(1, 1, 1),
    TextureMap? baseColorMap,
    this.normalMap,
    this.metallicRoughnessMap,
    this.occlusionMap,
    this.emissiveMap,
    double normalScale = 1,
    double? normalScaleX,
    double? normalScaleY,
    Color3? color,
    TextureMap? colorMap,
    this.occlusionStrength = 1,
    this.specularAntiAliasingVariance = .15,
    this.specularAntiAliasingThreshold = .2,
    this.localReflections = true,
    this.metallic = 0,
    this.roughness = 1,
    this.emissive = const Color3(0, 0, 0),
    this.emissiveIntensity = 1,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.vertexColors,
    super.depthWrite,
  }) : normalScale = normalScaleX ?? normalScale,
       normalScaleY = normalScaleY ?? normalScale,
       super(color: color ?? baseColor, colorMap: colorMap ?? baseColorMap) {
    for (final entry in {
      'metallic': metallic,
      'roughness': roughness,
      'occlusionStrength': occlusionStrength,
      'specularAntiAliasingVariance': specularAntiAliasingVariance,
      'specularAntiAliasingThreshold': specularAntiAliasingThreshold,
    }.entries) {
      if (!entry.value.isFinite || entry.value < 0 || entry.value > 1) {
        throw ArgumentError.value(entry.value, entry.key, 'Expected [0, 1].');
      }
    }
    if (![
      this.normalScale,
      this.normalScaleY,
    ].every((v) => v.isFinite && v.abs() <= 1e6)) {
      throw ArgumentError.value(
        normalScale,
        'normalScale',
        'Expected finite [-1e6, 1e6].',
      );
    }
    for (final entry in {
      'normalMap': normalMap,
      'metallicRoughnessMap': metallicRoughnessMap,
      'occlusionMap': occlusionMap,
    }.entries) {
      if (entry.value != null && entry.value!.image.descriptor.format.isSrgb) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'Data maps require a linear texture format.',
        );
      }
    }
    emissive.toList();
    if (!emissiveIntensity.isFinite ||
        emissiveIntensity < 0 ||
        emissiveIntensity > 1e12) {
      throw ArgumentError.value(
        emissiveIntensity,
        'emissiveIntensity',
        'Expected [0, 1e12].',
      );
    }
  }
  @override
  bool get unlit => false;
  StandardMaterial copyWith({
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
    double? specularAntiAliasingVariance,
    double? specularAntiAliasingThreshold,
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
  }) => StandardMaterial(
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
    specularAntiAliasingVariance:
        specularAntiAliasingVariance ?? this.specularAntiAliasingVariance,
    specularAntiAliasingThreshold:
        specularAntiAliasingThreshold ?? this.specularAntiAliasingThreshold,
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
