import 'dart:typed_data';
import '../math/color3.dart';
import '../resources/texture_image.dart';
part 'primitives.dart';

/// Opaque ignores alpha; mask discards below the cutoff; blend uses source-over.
enum MaterialAlphaMode { opaque, mask, blend }

/// Automatic writes depth for opaque and masked materials, but not blended ones.
enum DepthWrite { automatic, enabled, disabled }

sealed class MeshMaterial {
  final Color3 color;
  final TextureMap? colorMap;
  final MaterialAlphaMode alphaMode;
  final double opacity, alphaCutoff;
  final bool depthTest;
  final DepthWrite depthWrite;
  MeshMaterial({
    Color3? color,
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
    if (!alphaCutoff.isFinite || alphaCutoff < 0 || alphaCutoff > 1) {
      throw ArgumentError.value(
        alphaCutoff,
        'alphaCutoff',
        'Must be in [0, 1].',
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
    TextureMap? colorMap,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => DiffuseMaterial(
    color: color ?? this.color,
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
    TextureMap? colorMap,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    DepthWrite? depthWrite,
  }) => UnlitMaterial(
    color: color ?? this.color,
    colorMap: colorMap ?? this.colorMap,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}
