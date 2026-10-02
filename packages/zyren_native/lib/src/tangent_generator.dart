import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart' as native;

/// MikkTSpace default tangent generation and seam splitting on a CPU isolate.
/// At most two calls per Dart isolate can run at once. No GPU is created.
final class NativeTangentGenerator implements TangentGenerator {
  static int _active = 0;
  const NativeTangentGenerator();
  @override
  Future<GeometryData> generate(
    GeometryData geometry, {
    int uvSet = 0,
    TangentGenerationLimits limits = const TangentGenerationLimits(),
  }) async {
    limits.validateInput(geometry, uvSet: uvSet);
    if (_active >= 2) {
      throw const TangentGenerationException(
        TangentGenerationError.busy,
        'Two tangent jobs are already active. Retry after one completes.',
      );
    }
    _active++;
    try {
      return await _run(geometry, uvSet, limits);
    } finally {
      _active--;
    }
  }
}

Future<GeometryData> _run(
  GeometryData geometry,
  int uvSet,
  TangentGenerationLimits limits,
) => Isolate.run(
  () => _generate(geometry, uvSet, limits),
  debugName: 'zyren-mikktspace',
);

GeometryData _generate(
  GeometryData geometry,
  int uvSet,
  TangentGenerationLimits limits,
) {
  final changed = [
    for (final target in geometry.morphTargets)
      (target.positions?.any((v) => v != 0) ?? false) ||
          (target.normals?.any((v) => v != 0) ?? false),
  ];
  final passes = 1 + changed.where((value) => value).length;
  final corners = geometry.indices.length,
      vertices = geometry.layout.vertexCount;
  final length = corners * 4;
  // Native position/normal/UV/index arrays, a reusable output and retained Dart
  // corner streams. Input geometry copies and remapping structures are separate.
  final bridgeBytes = vertices * 32 + corners * 4 + length * 4 * (passes + 1);
  final scratch = limits.maxWorkingBytes - bridgeBytes;
  final iterations = limits.maxIterations ~/ passes;
  if (scratch < 1 || iterations < 1) {
    throw const TangentGenerationException(
      TangentGenerationError.limitExceeded,
      'Tangent poses exceed the working payload or iteration budget.',
    );
  }
  return using((arena) {
    final positions = arena<Float>(vertices * 3);
    final normals = arena<Float>(vertices * 3);
    final sourcePositions =
        geometry.attributes[VertexSemantic.position]!.data as Float32List;
    final sourceNormals =
        geometry.attributes[VertexSemantic.normal]!.data as Float32List;
    final positionValues = positions.asTypedList(vertices * 3);
    final normalValues = normals.asTypedList(vertices * 3);
    final sourceUvs =
        geometry
                .attributes[uvSet == 0
                    ? VertexSemantic.uv0
                    : VertexSemantic.uv1]!
                .data
            as Float32List;
    final uvs = arena<Float>(sourceUvs.length)
      ..asTypedList(sourceUvs.length).setAll(0, sourceUvs);
    final indices = arena<Uint32>(corners)
      ..asTypedList(corners).setAll(0, geometry.indices);
    final output = arena<Float>(length);
    final options = arena<native.NativeTangentLimits>();
    options.ref
      ..version = 1
      ..maxWorkingBytes = scratch
      ..maxIterations = iterations;
    Float32List run(MorphTarget? target) {
      for (var i = 0; i < vertices * 3; i++) {
        positionValues[i] = sourcePositions[i] + (target?.positions?[i] ?? 0);
        normalValues[i] = sourceNormals[i] + (target?.normals?[i] ?? 0);
      }
      final status = native.generateTangents(
        positions,
        normals,
        uvs,
        vertices,
        indices,
        corners,
        options,
        output,
        length,
      );
      if (status != 0) {
        throw TangentGenerationException(
          switch (status) {
            1 => TangentGenerationError.invalidData,
            2 => TangentGenerationError.limitExceeded,
            3 => TangentGenerationError.busy,
            _ => TangentGenerationError.internal,
          },
          switch (status) {
            1 =>
              'A base or morph pose cannot produce finite MikkTSpace tangents. Positions and UVs must be within ±1e15.',
            2 =>
              'Tangent generation exceeded its scratch, iteration or recursion limit.',
            3 =>
              'The native tangent scratch budget is in use. Retry after an active job completes.',
            _ => 'Native tangent generation failed.',
          },
        );
      }
      return Float32List.fromList(output.asTypedList(length));
    }

    final base = run(null);
    final morphs = [
      for (var i = 0; i < geometry.morphTargets.length; i++)
        changed[i] ? run(geometry.morphTargets[i]) : base,
    ];
    return geometry.withCornerTangents(
      base,
      morphTangents: morphs,
      limits: limits,
    );
  });
}
