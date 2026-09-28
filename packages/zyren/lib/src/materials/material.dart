import 'dart:typed_data';
import '../math/color3.dart';
import '../resources/texture_image.dart';
import '../resources/resource_scope.dart'
    show MeshShader, PostProcessDescriptor;
part 'primitives.dart';
part 'shader_material.dart';

/// Opaque ignores alpha; mask discards below the cutoff; blend uses source-over.
enum MaterialAlphaMode { opaque, mask, blend }

/// Automatic writes depth for opaque and masked materials, but not blended ones.
enum DepthWrite { automatic, enabled, disabled }

/// Triangle faces to render. Winding follows the full world transform, including
/// mirrored parents. Double-sided and back-face lighting reverse back normals.
enum MaterialSide { doubleSided, front, back }

sealed class MeshMaterial {
  final Color3 color;
  final MaterialSide side;
  final TextureMap? colorMap;
  final MaterialAlphaMode alphaMode;
  final double opacity, alphaCutoff;
  final bool depthTest;
  final DepthWrite depthWrite;
  MeshMaterial({
    Color3? color,
    this.side = MaterialSide.doubleSided,
    this.colorMap,
    this.alphaMode = MaterialAlphaMode.opaque,
    this.opacity = 1,
    this.alphaCutoff = .5,
    this.depthTest = true,
    this.depthWrite = DepthWrite.automatic,
  }) : color =
           color ??
           (colorMap == null
               ? const Color3(.4, .6, .9)
               : const Color3(1, 1, 1)) {
    this.color.toList();
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity', 'Must be in [0, 1].');
    }
    if (!alphaCutoff.isFinite ||
        alphaCutoff < 0 ||
        alphaCutoff > 3.4028234663852886e38) {
      throw ArgumentError.value(
        alphaCutoff,
        'alphaCutoff',
        'Must be nonnegative and fit finite float32 storage.',
      );
    }
  }
  bool get unlit;
  int get primitiveKind => 0;
  double get primitiveSize => 1;
  SizeUnits get sizeUnits => SizeUnits.pixels;
  PointShape get pointShape => PointShape.square;
  bool get writesDepth => switch (depthWrite) {
    DepthWrite.automatic => alphaMode != MaterialAlphaMode.blend,
    DepthWrite.enabled => true,
    DepthWrite.disabled => false,
  };
}

final class DiffuseMaterial extends MeshMaterial {
  DiffuseMaterial({
    super.color,
    super.side,
    super.colorMap,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  });
  @override
  bool get unlit => false;
  DiffuseMaterial copyWith({
    Color3? color,
    MaterialSide? side,
    TextureMap? colorMap,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => DiffuseMaterial(
    color: color ?? this.color,
    side: side ?? this.side,
    colorMap: colorMap ?? this.colorMap,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}

final class UnlitMaterial extends MeshMaterial {
  UnlitMaterial({
    super.color,
    super.side,
    super.colorMap,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.depthWrite,
  });
  @override
  bool get unlit => true;
  UnlitMaterial copyWith({
    Color3? color,
    MaterialSide? side,
    TextureMap? colorMap,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => UnlitMaterial(
    color: color ?? this.color,
    side: side ?? this.side,
    colorMap: colorMap ?? this.colorMap,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
