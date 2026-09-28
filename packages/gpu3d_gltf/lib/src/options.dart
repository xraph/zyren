import 'limits.dart';

enum GltfMaterialMode { standard, unlitDiagnostic }

/// Standard mode requires a qualified material path. The current native profile
/// supports KHR_materials_unlit; diagnostic mode approximates PBR with base color.
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
