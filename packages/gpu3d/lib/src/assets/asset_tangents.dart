part of 'asset_scope.dart';

extension TangentPreparation on AssetDecodeContext {
  /// Generates and accounts for a complete replacement geometry. Authored
  /// tangents are replaced; loaders decide whether generation is necessary.
  Future<GeometryData> generateTangents(
    GeometryData geometry, {
    int uvSet = 0,
    String? fieldPath,
  }) {
    final future = _decodeTail.then((_) async {
      cancellation.throwIfCancelled();
      final generator = _services.tangentGenerator;
      if (generator == null) {
        throw AssetLoadException(
          AssetLoadError.unsupportedFeature,
          'No tangent generator is configured. Set AssetServices.tangentGenerator to prepare missing tangents.',
          sourceUri: sourceUri,
          fieldPath: fieldPath,
        );
      }
      final remaining = limits.maxDecodedBytes - _decodedBytes;
      if (remaining <= 0) {
        throw _limit('Decoded bytes exceed the job budget.', fieldPath);
      }
      final tangentLimits = TangentGenerationLimits(
        maxOutputBytes: math.min(remaining, limits.tangents.maxOutputBytes),
        maxWorkingBytes: limits.tangents.maxWorkingBytes,
        maxIterations: limits.tangents.maxIterations,
      );
      late final GeometryData result;
      try {
        tangentLimits.validateInput(geometry, uvSet: uvSet);
        result = await generator.generate(
          geometry,
          uvSet: uvSet,
          limits: tangentLimits,
        );
      } on TangentGenerationException catch (error) {
        throw AssetLoadException(
          switch (error.code) {
            TangentGenerationError.invalidData => AssetLoadError.invalidData,
            TangentGenerationError.limitExceeded =>
              AssetLoadError.limitExceeded,
            _ => AssetLoadError.decodeFailed,
          },
          error.message,
          sourceUri: sourceUri,
          fieldPath: fieldPath,
          cause: error,
        );
      }
      cancellation.throwIfCancelled();
      if (!result.attributes.containsKey(VertexSemantic.tangent)) {
        throw AssetLoadException(
          AssetLoadError.decodeFailed,
          'The tangent generator returned geometry without tangents.',
          sourceUri: sourceUri,
          fieldPath: fieldPath,
        );
      }
      if (result.byteLength > tangentLimits.maxOutputBytes) {
        throw _limit('Generated geometry exceeds its byte budget.', fieldPath);
      }
      reserveDecodedBytes(result.byteLength, fieldPath: fieldPath);
      return result;
    });
    _decodeTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }
}
