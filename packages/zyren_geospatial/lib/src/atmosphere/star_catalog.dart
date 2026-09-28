import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'star_data.dart';

/// One J2000 equatorial direction with apparent magnitude and linear RGB colour.
final class Star {
  final Vec3 directionECI;
  final double magnitude;
  final Color3 color;
  const Star._(this.directionECI, this.magnitude, this.color);
}

/// Immutable decoded catalogue. The packed source has ten bytes per star:
/// three signed normalized int16 coordinates, magnitude [-2, 8], and RGB8.
final class StarCatalog {
  final List<Star> stars;
  StarCatalog._(Iterable<Star> values) : stars = List.unmodifiable(values);
  static final _bright = StarCatalog.fromBytes(base64Decode(brightStarData));
  factory StarCatalog.brightStars() => _bright;
  factory StarCatalog.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length % 10 != 0 || bytes.length > 163840) {
      throw ArgumentError(
        'A star catalogue requires 1 to 16384 ten-byte records.',
      );
    }
    final view = ByteData.sublistView(bytes);
    final stars = <Star>[];
    for (var offset = 0; offset < bytes.length; offset += 10) {
      double coordinate(int index) =>
          math.max(-1, view.getInt16(offset + index, Endian.little) / 32767);
      final direction = Vec3(coordinate(0), coordinate(2), coordinate(4));
      if (direction.length2 == 0) {
        throw ArgumentError('Star direction is zero.');
      }
      stars.add(
        Star._(
          direction.normalized(),
          -2 + 10 * bytes[offset + 6] / 255,
          Color3(
            bytes[offset + 7] / 255,
            bytes[offset + 8] / 255,
            bytes[offset + 9] / 255,
          ),
        ),
      );
    }
    return StarCatalog._(stars);
  }
}
