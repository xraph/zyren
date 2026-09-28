import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:gpu3d/gpu3d.dart';
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
  debugName: 'gpu3d-mikktspace',
);

GeometryData _generate(
  GeometryData geometry,
  int uvSet,
  TangentGenerationLimits limits,
) => using((arena) {
  Pointer<Float> attribute(VertexSemantic semantic) {
    final data = geometry.attributes[semantic]!.data as Float32List;
    return arena<Float>(data.length)..asTypedList(data.length).setAll(0, data);
  }

  final indices = arena<Uint32>(geometry.indices.length)
    ..asTypedList(geometry.indices.length).setAll(0, geometry.indices);
  final length = geometry.indices.length * 4;
  final output = arena<Float>(length);
  final options = arena<native.NativeTangentLimits>();
  options.ref
    ..version = 1
    ..maxWorkingBytes = limits.maxWorkingBytes
    ..maxIterations = limits.maxIterations;
  final status = native.generateTangents(
    attribute(VertexSemantic.position),
    attribute(VertexSemantic.normal),
    attribute(uvSet == 0 ? VertexSemantic.uv0 : VertexSemantic.uv1),
    geometry.layout.vertexCount,
    indices,
    geometry.indices.length,
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
          'Geometry cannot produce finite MikkTSpace tangents. Positions and UVs must be within ±1e15.',
        2 =>
          'Tangent generation exceeded its scratch, iteration or recursion limit.',
        3 =>
          'The native tangent scratch budget is in use. Retry after an active job completes.',
        _ => 'Native tangent generation failed.',
      },
    );
  }
  return geometry.withCornerTangents(
    output.asTypedList(length),
    limits: limits,
  );
});
