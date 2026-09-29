part of 'material.dart';

/// Pixels are physical target pixels. World sizes do not inherit object scale.
enum SizeUnits { pixels, world }

enum PointShape { square, circle }

final class LineMaterial extends MeshMaterial {
  final double width;
  final SizeUnits widthUnits;
  LineMaterial({
    super.color,
    this.width = 1,
    this.widthUnits = SizeUnits.pixels,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.vertexColors,
    super.depthWrite,
  }) {
    _validateSize(width, widthUnits);
  }
  @override
  bool get unlit => true;
  @override
  int get primitiveKind => 1;
  @override
  double get primitiveSize => width;
  @override
  SizeUnits get sizeUnits => widthUnits;
  LineMaterial copyWith({
    Color3? color,
    double? width,
    SizeUnits? widthUnits,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    bool? vertexColors,
    DepthWrite? depthWrite,
  }) => LineMaterial(
    color: color ?? this.color,
    width: width ?? this.width,
    widthUnits: widthUnits ?? this.widthUnits,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    vertexColors: vertexColors ?? this.vertexColors,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}

final class PointsMaterial extends MeshMaterial {
  final double size;
  @override
  final SizeUnits sizeUnits;
  final PointShape shape;
  PointsMaterial({
    super.color,
    this.size = 4,
    this.sizeUnits = SizeUnits.pixels,
    this.shape = PointShape.circle,
    super.alphaMode,
    super.opacity,
    super.alphaCutoff,
    super.depthTest,
    super.vertexColors,
    super.depthWrite,
  }) {
    _validateSize(size, sizeUnits);
  }
  @override
  bool get unlit => true;
  @override
  int get primitiveKind => 2;
  @override
  double get primitiveSize => size;
  @override
  PointShape get pointShape => shape;
  PointsMaterial copyWith({
    Color3? color,
    double? size,
    SizeUnits? sizeUnits,
    PointShape? shape,
    MaterialAlphaMode? alphaMode,
    double? opacity,
    double? alphaCutoff,
    bool? depthTest,
    bool? vertexColors,
    DepthWrite? depthWrite,
  }) => PointsMaterial(
    color: color ?? this.color,
    size: size ?? this.size,
    sizeUnits: sizeUnits ?? this.sizeUnits,
    shape: shape ?? this.shape,
    alphaMode: alphaMode ?? this.alphaMode,
    opacity: opacity ?? this.opacity,
    alphaCutoff: alphaCutoff ?? this.alphaCutoff,
    depthTest: depthTest ?? this.depthTest,
    vertexColors: vertexColors ?? this.vertexColors,
    depthWrite: depthWrite ?? this.depthWrite,
  );
}

void _validateSize(double size, SizeUnits units) {
  final maximum = units == SizeUnits.pixels ? 4096.0 : 1e12;
  if (!size.isFinite ||
      size <= 0 ||
      size > maximum ||
      Float32List.fromList([size]).single <= 0) {
    throw ArgumentError.value(
      size,
      'size',
      'Must be positive and at most $maximum.',
    );
  }
}
