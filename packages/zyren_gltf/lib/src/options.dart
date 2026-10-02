import 'limits.dart';

enum GltfMaterialMode { standard, unlitDiagnostic }

/// Standard mode imports metallic/roughness and KHR_materials_unlit materials.
/// Diagnostic mode approximates PBR with unlit base color and reports a warning.
final class GltfOptions {
  final GltfLimits limits;
  final GltfMaterialMode materialMode;
  const GltfOptions({
    this.limits = const GltfLimits(),
    this.materialMode = GltfMaterialMode.standard,
  });
  @override
  bool operator ==(Object other) =>
      other is GltfOptions &&
      limits == other.limits &&
      materialMode == other.materialMode;
  @override
  int get hashCode => Object.hash(limits, materialMode);
}
