import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'cloud.dart';

/// ASCII XYZ: three finite numbers per record, blank lines and # comments.
/// Extra columns are rejected so classifications or colors cannot be lost silently.
final class XyzPointCloudLoader extends AssetLoader<PointCloudData> {
  final String sourceVersion;
  final PointCloudLimits limits;
  const XyzPointCloudLoader({
    required this.sourceVersion,
    this.limits = const PointCloudLimits(),
  });

  @override
  Object get cacheKey => (
    sourceVersion,
    limits.maxPoints,
    limits.maxSourceBytes,
    limits.maxLineBytes,
    limits.maxCoordinateBytes,
  );

  @override
  Future<DecodedAsset<PointCloudData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final data = await parse(
      source.bytes,
      sourceUri: context.sourceUri,
      cancellation: context.cancellation,
      reserveCoordinateBytes: context.reserveDecodedBytes,
    );
    return DecodedAsset(create: () => data, release: (_) {});
  }

  /// Checks the source before decoding strings and reserves each record before
  /// retaining its coordinates. Cooperative yields let scope cancellation run.
  Future<PointCloudData> parse(
    Uint8List bytes, {
    required Uri sourceUri,
    LoadCancellation? cancellation,
    void Function(int)? reserveCoordinateBytes,
  }) async {
    limits.validate();
    if (bytes.length > limits.maxSourceBytes) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'XYZ source exceeds its byte budget.',
      );
    }
    cancellation?.throwIfCancelled();
    final points = <Vec3>[];
    var start = 0, line = 1;
    for (var end = 0; end <= bytes.length; end++) {
      if (end - start > limits.maxLineBytes) {
        throw AssetLoadException(
          AssetLoadError.limitExceeded,
          'XYZ line $line exceeds its byte budget.',
        );
      }
      if (end < bytes.length && bytes[end] != 10) continue;
      cancellation?.throwIfCancelled();
      final String value;
      try {
        value = ascii.decode(Uint8List.sublistView(bytes, start, end)).trim();
      } on FormatException {
        throw AssetLoadException(
          AssetLoadError.invalidData,
          'XYZ line $line is not ASCII.',
        );
      }
      if (value.isNotEmpty && !value.startsWith('#')) {
        limits.checkCount(points.length + 1);
        final fields = value.split(RegExp(r'\s+'));
        final values = fields.map(double.tryParse).toList();
        if (values.length != 3 || values.any((v) => v == null || !v.isFinite)) {
          throw AssetLoadException(
            AssetLoadError.invalidData,
            'XYZ line $line needs three finite coordinates.',
          );
        }
        reserveCoordinateBytes?.call(24);
        points.add(Vec3(values[0]!, values[1]!, values[2]!));
      }
      start = end + 1;
      line++;
      if (line % 1024 == 0) await Future<void>.delayed(Duration.zero);
    }
    cancellation?.throwIfCancelled();
    if (points.isEmpty) {
      throw AssetLoadException(
        AssetLoadError.invalidData,
        'XYZ source contains no point records.',
      );
    }
    return PointCloudData(
      sourceUri: sourceUri,
      sourceVersion: sourceVersion,
      points: points,
      limits: limits,
    );
  }
}
