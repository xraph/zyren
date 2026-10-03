import 'dart:math' as math;
import '../geodesy.dart';
import '../tiling.dart';

void validateGeoBounds(GeographicRectangle bounds) {
  if (bounds.toList().any((v) => !v.isFinite) ||
      bounds.west < -math.pi ||
      bounds.west > math.pi ||
      bounds.east < -math.pi ||
      bounds.east > math.pi ||
      bounds.south < -math.pi / 2 ||
      bounds.north > math.pi / 2 ||
      bounds.width <= 0 ||
      bounds.width > math.pi * 2 ||
      bounds.height <= 0) {
    throw ArgumentError('Invalid geographic coverage.');
  }
}

List<GeographicRectangle> splitGeoBounds(GeographicRectangle bounds) {
  validateGeoBounds(bounds);
  if (bounds.west <= bounds.east) return [bounds];
  return [
    if (bounds.west < math.pi)
      GeographicRectangle(bounds.west, bounds.south, math.pi, bounds.north),
    if (bounds.east > -math.pi)
      GeographicRectangle(-math.pi, bounds.south, bounds.east, bounds.north),
  ];
}

/// Coverage is a provider declaration. Unknown coverage never certifies a region.
final class GeoCoverage {
  final List<GeographicRectangle> rectangles;
  final bool known;
  final int minimumLevel, maximumLevel;
  final DateTime? start, end;
  GeoCoverage({
    required Iterable<GeographicRectangle> rectangles,
    this.known = true,
    this.minimumLevel = 0,
    this.maximumLevel = 24,
    this.start,
    this.end,
  }) : rectangles = List.unmodifiable(rectangles.take(129)) {
    if (this.rectangles.length > 128 ||
        minimumLevel < 0 ||
        maximumLevel > 30 ||
        maximumLevel < minimumLevel ||
        (start != null && !start!.isUtc) ||
        (end != null && !end!.isUtc) ||
        (start != null && end != null && start!.isAfter(end!))) {
      throw ArgumentError('Invalid coverage limits.');
    }
    for (final rectangle in this.rectangles) {
      validateGeoBounds(rectangle);
    }
  }
  bool? contains(Geodetic point) {
    if (!known) return null;
    if (!point.longitude.isFinite ||
        !point.latitude.isFinite ||
        point.longitude.abs() > math.pi ||
        point.latitude.abs() > math.pi / 2) {
      return false;
    }
    return rectangles
        .expand(splitGeoBounds)
        .any(
          (r) =>
              point.longitude >= r.west &&
              point.longitude <= r.east &&
              point.latitude >= r.south &&
              point.latitude <= r.north,
        );
  }

  bool covers(
    GeographicRectangle bounds, {
    required int minimumLevel,
    required int maximumLevel,
    DateTime? start,
    DateTime? end,
  }) {
    if (!known ||
        minimumLevel < this.minimumLevel ||
        maximumLevel > this.maximumLevel ||
        (this.start != null &&
            (start == null || start.isBefore(this.start!))) ||
        (this.end != null && (end == null || end.isAfter(this.end!)))) {
      return false;
    }
    var remaining = splitGeoBounds(bounds);
    for (final cover in rectangles.expand(splitGeoBounds)) {
      final next = <GeographicRectangle>[];
      for (final cell in remaining) {
        final west = math.max(cell.west, cover.west),
            east = math.min(cell.east, cover.east);
        final south = math.max(cell.south, cover.south),
            north = math.min(cell.north, cover.north);
        if (east <= west || north <= south) {
          next.add(cell);
          continue;
        }
        if (cell.west < west) {
          next.add(
            GeographicRectangle(cell.west, cell.south, west, cell.north),
          );
        }
        if (cell.east > east) {
          next.add(
            GeographicRectangle(east, cell.south, cell.east, cell.north),
          );
        }
        if (cell.south < south) {
          next.add(GeographicRectangle(west, cell.south, east, south));
        }
        if (cell.north > north) {
          next.add(GeographicRectangle(west, north, east, cell.north));
        }
      }
      remaining = next;
      if (remaining.isEmpty) return true;
      if (remaining.length > 4096) return false;
    }
    return remaining.isEmpty;
  }
}
