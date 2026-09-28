part of 'material.dart';

/// Metallic/roughness material in linear light. Direct lighting uses explicit
/// scene lights; emission is independent of them.
final class StandardMaterial extends MeshMaterial {
  final double metallic, roughness, emissiveIntensity;
  final Color3 emissive;
  Color3 get baseColor => color;
  TextureMap? get baseColorMap => colorMap;
  StandardMaterial({
    Color3 baseColor = const Color3(1, 1, 1),
    TextureMap? baseColorMap,
    this.metallic = 0,
    this.roughness = 1,
    this.emissive = const Color3(0, 0, 0),
    this.emissiveIntensity = 1,
    super.side,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  }) : super(color: baseColor, colorMap: baseColorMap) {
    for (final entry in {
      'metallic': metallic,
      'roughness': roughness,
    }.entries) {
      if (!entry.value.isFinite || entry.value < 0 || entry.value > 1) {
        throw ArgumentError.value(entry.value, entry.key, 'Expected [0, 1].');
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
    Color3? baseColor,
    TextureMap? baseColorMap,
    bool clearBaseColorMap = false,
    double? metallic,
    double? roughness,
    Color3? emissive,
    double? emissiveIntensity,
    MaterialSide? side,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => StandardMaterial(
    baseColor: baseColor ?? this.baseColor,
    baseColorMap: clearBaseColorMap ? null : baseColorMap ?? this.baseColorMap,
    metallic: metallic ?? this.metallic,
    roughness: roughness ?? this.roughness,
    emissive: emissive ?? this.emissive,
    emissiveIntensity: emissiveIntensity ?? this.emissiveIntensity,
    side: side ?? this.side,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
