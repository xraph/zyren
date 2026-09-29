part of 'geometry.dart';

/// Connected segments with butt ends. Set [closed] to connect the last point.
class LineGeometry extends BufferGeometry {
  factory LineGeometry({
    required Iterable<Vec3> points,
    bool closed = false,
    bool dynamic = false,
  }) => LineGeometry._(
    _primitivePositions(points, 2),
    GeometryTopology.lineStrip,
    closed,
    dynamic,
  );

  /// Independent pairs, useful for grids, edges and measurement guides.
  factory LineGeometry.segments({
    required Iterable<Vec3> points,
    bool dynamic = false,
  }) => LineGeometry._(
    _primitivePositions(points, 2),
    GeometryTopology.lineSegments,
    false,
    dynamic,
  );
  LineGeometry._(
    List<double> positions,
    GeometryTopology topology,
    bool closed,
    bool dynamic,
  ) : super(
        positions: positions,
        normals: _primitiveNormals(positions.length ~/ 3),
        indices: [
          ...List.generate(positions.length ~/ 3, (i) => i),
          if (closed) 0,
        ],
        topology: topology,
        dynamic: dynamic,
      );
}

/// One camera-facing marker per point. Positions can be shared by several views.
class PointGeometry extends BufferGeometry {
  factory PointGeometry({
    required Iterable<Vec3> points,
    bool dynamic = false,
  }) => PointGeometry._(_primitivePositions(points, 1), dynamic);
  PointGeometry._(List<double> positions, bool dynamic)
    : super(
        positions: positions,
        normals: _primitiveNormals(positions.length ~/ 3),
        indices: List.generate(positions.length ~/ 3, (i) => i),
        topology: GeometryTopology.points,
        dynamic: dynamic,
      );
}

List<double> _primitivePositions(Iterable<Vec3> points, int minimum) {
  final positions = <double>[];
  for (final point in points) {
    if (!point.isFinite || positions.length >= 3000000) {
      throw ArgumentError(
        'Primitive positions must be finite and fit the vertex budget.',
      );
    }
    positions.addAll(point.storage);
  }
  if (positions.length < minimum * 3) {
    throw ArgumentError('Geometry needs at least $minimum points.');
  }
  return positions;
}

List<double> _primitiveNormals(int count) => [
  for (var i = 0; i < count; i++) ...[0, 0, 1],
];
