part of 'scene.dart';

class Line extends Mesh {
  Line(
    LineGeometry super.geometry,
    LineMaterial super.material, {
    super.name,
    super.renderOrder,
  });
  @override
  LineMaterial get material => super.material as LineMaterial;
  @override
  set material(covariant LineMaterial value) => super.material = value;
}

class Points extends Mesh {
  Points(
    PointGeometry super.geometry,
    PointsMaterial super.material, {
    super.name,
    super.renderOrder,
  });
  @override
  PointsMaterial get material => super.material as PointsMaterial;
  @override
  set material(covariant PointsMaterial value) => super.material = value;
}
