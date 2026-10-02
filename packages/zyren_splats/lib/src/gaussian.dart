import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// Symmetric covariance in squared source units. Requires positive definiteness.
final class GaussianCovariance {
  final double xx, xy, xz, yy, yz, zz;
  GaussianCovariance({
    required this.xx,
    this.xy = 0,
    this.xz = 0,
    required this.yy,
    this.yz = 0,
    required this.zz,
  }) {
    if ([xx, xy, xz, yy, yz, zz].any((v) => !v.isFinite) || xx <= 0) {
      throw ArgumentError('Covariance must be finite and positive definite.');
    }
    final l00 = math.sqrt(xx),
        l10 = xy / math.sqrt(xx),
        l20 = xz / math.sqrt(xx);
    final d11 = yy - l10 * l10;
    if (!l00.isFinite || !d11.isFinite || d11 <= 0) {
      throw ArgumentError('Covariance must be positive definite.');
    }
    final l21 = (yz - l20 * l10) / math.sqrt(d11);
    final d22 = zz - l20 * l20 - l21 * l21;
    if (!d22.isFinite || d22 <= 0) {
      throw ArgumentError('Covariance must be positive definite.');
    }
  }

  double bilinear(Vec3 a, Vec3 b) =>
      a.x * (xx * b.x + xy * b.y + xz * b.z) +
      a.y * (xy * b.x + yy * b.y + yz * b.z) +
      a.z * (xz * b.x + yz * b.y + zz * b.z);
}

/// Appearance only. A Gaussian mean does not establish a measured surface.
final class GaussianSplat {
  final Vec3 mean;
  final GaussianCovariance covariance;
  final Color3 color;
  final double opacity;
  GaussianSplat({
    required this.mean,
    required this.covariance,
    required this.color,
    this.opacity = 1,
  }) {
    if (!mean.isFinite ||
        [
          color.r,
          color.g,
          color.b,
          opacity,
        ].any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError(
        'Use a finite mean and linear RGB/opacity in [0, 1].',
      );
    }
  }
}

final class SplatLimits {
  final int maxSplats, maxUploadBytes, maxTargetBytes;
  const SplatLimits({
    this.maxSplats = 32768,
    this.maxUploadBytes = 2 * 1024 * 1024,
    this.maxTargetBytes = 16 * 1024 * 1024,
  });

  void validate() {
    RangeError.checkValueInInterval(maxSplats, 1, 32768, 'maxSplats');
    RangeError.checkValueInInterval(
      maxUploadBytes,
      64,
      64 * 1024 * 1024,
      'maxUploadBytes',
    );
    RangeError.checkValueInInterval(
      maxTargetBytes,
      4,
      256 * 1024 * 1024,
      'maxTargetBytes',
    );
  }

  void checkCount(int count) {
    if (count > maxSplats || count * 64 > maxUploadBytes) {
      throw StateError('Gaussian count or upload payload exceeds its budget.');
    }
  }
}

final class GaussianCloudData {
  final Uri sourceUri;
  final String sourceVersion;
  final List<GaussianSplat> splats;
  GaussianCloudData._(this.sourceUri, this.sourceVersion, this.splats);
  factory GaussianCloudData({
    required Uri sourceUri,
    required String sourceVersion,
    required Iterable<GaussianSplat> splats,
    SplatLimits limits = const SplatLimits(),
  }) {
    limits.validate();
    if (!sourceUri.hasScheme ||
        sourceUri.hasFragment ||
        sourceVersion.isEmpty ||
        sourceVersion.length > 1024) {
      throw ArgumentError(
        'Use an absolute URI without a fragment and a nonempty version.',
      );
    }
    final records = <GaussianSplat>[];
    for (final splat in splats) {
      limits.checkCount(records.length + 1);
      records.add(splat);
    }
    if (records.isEmpty) throw ArgumentError('A Gaussian cloud needs records.');
    return GaussianCloudData._(
      sourceUri,
      sourceVersion,
      List.unmodifiable(records),
    );
  }

  (Uri, String, int) identityAt(int index) {
    RangeError.checkValidIndex(index, splats);
    return (sourceUri, sourceVersion, index);
  }
}
