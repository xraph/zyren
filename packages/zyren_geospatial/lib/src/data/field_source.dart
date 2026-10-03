import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../world/reference.dart';
import '../world/sample.dart';
import '../world/time.dart';
import 'coverage.dart';
import 'policy.dart';
import 'resolver.dart';
import 'resource_key.dart';

abstract interface class GeoFieldSource<T extends Object> {
  String get id;
  String get revision;
  String get units;
  GeoHeightDatum? get datum;
  Future<GeoSample<T>> sample(Geodetic coordinate, GeoInstant time);
}

enum GeoFieldInterpolation { nearest, bilinear }

/// South-to-north rows over radian bounds, including both endpoint samples.
/// NaN marks missing coverage. Infinity is invalid data.
final class GeoScalarGrid {
  final int width, height;
  final GeographicRectangle bounds;
  final Float64List values;
  GeoScalarGrid({
    required this.width,
    required this.height,
    required this.bounds,
    required Float64List values,
  }) : values = _copy(width, height, values) {
    validateGeoBounds(bounds);
  }
  static Float64List _copy(int width, int height, Float64List values) {
    if (width < 2 ||
        height < 2 ||
        width > 2048 ||
        height > 2048 ||
        width * height > 262144 ||
        values.length != width * height ||
        values.any((v) => v.isInfinite)) {
      throw ArgumentError('Invalid bounded scalar field grid.');
    }
    return Float64List.fromList(values).asUnmodifiableView();
  }

  Uint8List encode() {
    final output = ByteData(48 + values.length * 8);
    output.setUint32(0, 0x3146475a, Endian.little);
    output.setUint32(4, width, Endian.little);
    output.setUint32(8, height, Endian.little);
    final edges = bounds.toList();
    for (var i = 0; i < 4; i++) {
      output.setFloat64(16 + i * 8, edges[i], Endian.little);
    }
    for (var i = 0; i < values.length; i++) {
      output.setFloat64(48 + i * 8, values[i], Endian.little);
    }
    return output.buffer.asUint8List();
  }

  factory GeoScalarGrid.decode(Uint8List bytes, {int maxCells = 262144}) {
    try {
      if (maxCells < 4 ||
          maxCells > 262144 ||
          bytes.length < 48 ||
          bytes.length > 48 + maxCells * 8) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      final data = ByteData.sublistView(bytes);
      final width = data.getUint32(4, Endian.little),
          height = data.getUint32(8, Endian.little);
      if (data.getUint32(0, Endian.little) != 0x3146475a ||
          data.getUint32(12, Endian.little) != 0 ||
          width < 2 ||
          height < 2 ||
          width * height > maxCells ||
          bytes.length != 48 + width * height * 8) {
        throw const GeoDataException(GeoDataError.corrupt);
      }
      final values = Float64List(width * height);
      for (var i = 0; i < values.length; i++) {
        values[i] = data.getFloat64(48 + i * 8, Endian.little);
      }
      return GeoScalarGrid(
        width: width,
        height: height,
        bounds: GeographicRectangle.fromList([
          for (var i = 0; i < 4; i++)
            data.getFloat64(16 + i * 8, Endian.little),
        ]),
        values: values,
      );
    } on GeoDataException {
      rethrow;
    } catch (e) {
      throw GeoDataException(GeoDataError.corrupt, cause: e);
    }
  }
  double? at(Geodetic coordinate, GeoFieldInterpolation interpolation) {
    if (!GeoCoverage(rectangles: [bounds]).contains(coordinate)!) return null;
    final longitude = coordinate.longitude < bounds.west
        ? coordinate.longitude + math.pi * 2
        : coordinate.longitude;
    final x = ((longitude - bounds.west) / bounds.width * (width - 1)).clamp(
      0.0,
      width - 1.0,
    );
    final y =
        ((coordinate.latitude - bounds.south) / bounds.height * (height - 1))
            .clamp(0.0, height - 1.0);
    if (interpolation == GeoFieldInterpolation.nearest) {
      final value = values[y.round() * width + x.round()];
      return value.isNaN ? null : value;
    }
    final ix = math.min(x.floor(), width - 2),
        iy = math.min(y.floor(), height - 2);
    final tx = x - ix, ty = y - iy;
    final a = values[iy * width + ix],
        b = values[iy * width + ix + 1],
        c = values[(iy + 1) * width + ix],
        d = values[(iy + 1) * width + ix + 1];
    if ([a, b, c, d].any((v) => v.isNaN)) return null;
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
  }
}

/// Decoded data is cached by verified content digest. Each query still checks
/// the resolver's current authorization, freshness and encoded byte policy.
final class GeoGridFieldSource implements GeoFieldSource<double> {
  @override
  final String id, units;
  @override
  String get revision => key.sourceVersion;
  @override
  final GeoHeightDatum? datum;
  final GeoResourceKey key;
  final GeographicRectangle bounds;
  final GeoResourceResolver resolver;
  final GeoReadPolicy policy;
  final GeoFieldInterpolation interpolation;
  final int maxCells;
  final double? errorBound;
  final _cancellation = LoadCancellationSource();
  GeoScalarGrid? _decoded;
  String? _checksum;
  GeoGridFieldSource({
    required this.id,
    required this.units,
    required this.datum,
    required this.key,
    required this.bounds,
    required this.resolver,
    required this.policy,
    this.interpolation = GeoFieldInterpolation.bilinear,
    this.maxCells = 262144,
    this.errorBound,
  }) {
    validateGeoBounds(bounds);
    if (id.trim().isEmpty ||
        id.length > 128 ||
        units.trim().isEmpty ||
        units.length > 128 ||
        maxCells < 4 ||
        maxCells > 262144 ||
        (errorBound != null && (!errorBound!.isFinite || errorBound! < 0))) {
      throw ArgumentError('Invalid field descriptor.');
    }
  }
  int get decodedBytes => (_decoded?.values.length ?? 0) * 8;
  @override
  Future<GeoSample<double>> sample(Geodetic coordinate, GeoInstant time) async {
    GeoSample<double> result(
      GeoSampleAvailability availability, {
      double? value,
      Duration? age,
      Object? failure,
    }) => GeoSample(
      availability: availability,
      value: value,
      frameId: 'geodetic-WGS84',
      frameRevision: 0,
      sourceRevision: revision,
      units: units,
      time: time,
      age: age,
      error: errorBound,
      failure: failure,
    );
    if (_cancellation.isCancelled) {
      return result(
        GeoSampleAvailability.failed,
        failure: const GeoDataException(GeoDataError.closed),
      );
    }
    if (!GeoCoverage(rectangles: [bounds]).contains(coordinate)!) {
      return result(GeoSampleAvailability.outsideCoverage);
    }
    try {
      final resource = await resolver.read(
        key,
        policy,
        cancellation: _cancellation,
        maxBytes: 48 + maxCells * 8,
      );
      if (_checksum != resource.checksum) {
        final decoded = GeoScalarGrid.decode(
          resource.bytes,
          maxCells: maxCells,
        );
        if (decoded.bounds != bounds) {
          throw const GeoDataException(GeoDataError.corrupt);
        }
        _decoded = decoded;
        _checksum = resource.checksum;
      }
      final value = _decoded!.at(coordinate, interpolation);
      if (value == null) return result(GeoSampleAvailability.unavailable);
      final elapsed = resolver.now().difference(resource.fetchedAt);
      return result(
        resource.isFreshAt(resolver.now(), maxAge: policy.maxAge)
            ? GeoSampleAvailability.available
            : GeoSampleAvailability.stale,
        value: value,
        age: elapsed.isNegative ? Duration.zero : elapsed,
      );
    } on GeoDataException catch (e) {
      return result(
        e.code == GeoDataError.offlineMiss
            ? GeoSampleAvailability.unavailable
            : GeoSampleAvailability.failed,
        failure: e,
      );
    }
  }

  void dispose() {
    _cancellation.cancel();
    _decoded = null;
    _checksum = null;
  }
}
