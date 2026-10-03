import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'gaussian.dart';

enum SplatColorEncoding { linear, srgb }

/// Headerless 32-byte .splat records: XYZ/scale float32, RGBA bytes, WXYZ bytes.
/// This format carries no CRS, units, source color space or higher SH bands.
final class BinarySplatLoader extends AssetLoader<GaussianCloudData> {
  final String sourceVersion;
  final SplatColorEncoding colorEncoding;
  final SplatLimits limits;
  const BinarySplatLoader({
    required this.sourceVersion,
    required this.colorEncoding,
    this.limits = const SplatLimits(),
  });
  @override
  Object get cacheKey =>
      (sourceVersion, colorEncoding, limits.maxSplats, limits.maxUploadBytes);
  @override
  Future<DecodedAsset<GaussianCloudData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final data = await parse(
      source.bytes,
      sourceUri: context.sourceUri,
      cancellation: context.cancellation,
      reserveDecodedBytes: context.reserveDecodedBytes,
    );
    return DecodedAsset(create: () => data, release: (_) {});
  }

  Future<GaussianCloudData> parse(
    Uint8List bytes, {
    required Uri sourceUri,
    LoadCancellation? cancellation,
    void Function(int)? reserveDecodedBytes,
  }) async {
    limits.validate();
    cancellation?.throwIfCancelled();
    if (bytes.isEmpty || bytes.length % 32 != 0) {
      throw AssetLoadException(
        AssetLoadError.invalidData,
        'A .splat source needs complete 32-byte records.',
      );
    }
    final count = bytes.length ~/ 32;
    limits.checkCount(count);
    reserveDecodedBytes?.call(count * 104);
    final view = ByteData.sublistView(bytes), splats = <GaussianSplat>[];
    double color(int b) {
      final v = b / 255;
      return colorEncoding == SplatColorEncoding.linear
          ? v
          : v <= .04045
          ? v / 12.92
          : math.pow((v + .055) / 1.055, 2.4).toDouble();
    }

    for (var i = 0; i < count; i++) {
      cancellation?.throwIfCancelled();
      final offset = i * 32;
      double f(int n) => view.getFloat32(offset + n * 4, Endian.little);
      final mean = Vec3(f(0), f(1), f(2)), scale = Vec3(f(3), f(4), f(5));
      final q = [
        for (var j = 0; j < 4; j++) (bytes[offset + 28 + j] - 128) / 128,
      ];
      final norm = math.sqrt(q.fold<double>(0, (sum, v) => sum + v * v));
      if (!mean.isFinite ||
          !scale.isFinite ||
          scale.x <= 0 ||
          scale.y <= 0 ||
          scale.z <= 0 ||
          norm < 1e-6) {
        throw AssetLoadException(
          AssetLoadError.invalidData,
          'Invalid Gaussian position, scale or rotation at record $i.',
        );
      }
      final matrix = Mat4.compose(
        Vec3.zero,
        Quat(q[1] / norm, q[2] / norm, q[3] / norm, q[0] / norm),
        scale,
      ).storage;
      // Columns are the rotated principal axes multiplied by standard deviation.
      final x = Vec3(matrix[0], matrix[4], matrix[8]),
          y = Vec3(matrix[1], matrix[5], matrix[9]),
          z = Vec3(matrix[2], matrix[6], matrix[10]);
      splats.add(
        GaussianSplat(
          mean: mean,
          covariance: GaussianCovariance(
            xx: x.dot(x),
            xy: x.dot(y),
            xz: x.dot(z),
            yy: y.dot(y),
            yz: y.dot(z),
            zz: z.dot(z),
          ),
          color: Color3(
            color(bytes[offset + 24]),
            color(bytes[offset + 25]),
            color(bytes[offset + 26]),
          ),
          opacity: bytes[offset + 27] / 255,
        ),
      );
      if (i % 1024 == 0) await Future<void>.delayed(Duration.zero);
    }
    cancellation?.throwIfCancelled();
    return GaussianCloudData(
      sourceUri: sourceUri,
      sourceVersion: sourceVersion,
      splats: splats,
      limits: limits,
    );
  }
}
