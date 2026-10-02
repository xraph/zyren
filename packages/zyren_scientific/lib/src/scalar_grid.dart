import 'dart:typed_data';

import 'package:zyren/zyren.dart';

/// Units label supplied numbers. This package does not convert units.
final class ScientificUnit {
  final String quantity, symbol;

  ScientificUnit({required this.quantity, required this.symbol}) {
    if (quantity.trim().isEmpty ||
        symbol.trim().isEmpty ||
        quantity.length > 128 ||
        symbol.length > 128) {
      throw ArgumentError('Units need a quantity and symbol.');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ScientificUnit &&
      other.quantity == quantity &&
      other.symbol == symbol;

  @override
  int get hashCode => Object.hash(quantity, symbol);
}

enum ScientificDataKind { synthetic, measured, simulated }

/// Caller-supplied source identity and origin of the data, not a certification.
final class ScientificSource {
  final String id, description;
  final ScientificDataKind kind;

  ScientificSource({
    required this.id,
    required this.description,
    required this.kind,
  }) {
    if (id.trim().isEmpty ||
        description.trim().isEmpty ||
        id.length > 1024 ||
        description.length > 2048) {
      throw ArgumentError('A source needs an ID and description.');
    }
  }
}

/// Typed payload ceilings, excluding caller storage, VM overhead and GPU copies.
final class ScientificBudget {
  final int maxSamples, maxSliceCells, maxGeometryBytes;

  ScientificBudget({
    this.maxSamples = 1000000,
    this.maxSliceCells = 250000,
    this.maxGeometryBytes = 16 * 1024 * 1024,
  }) {
    if (maxSamples < 1 ||
        maxSamples > 1000000 ||
        maxSliceCells < 1 ||
        maxSliceCells > 250000 ||
        maxGeometryBytes < 1 ||
        maxGeometryBytes > 16 * 1024 * 1024) {
      throw ArgumentError(
        'Budgets must be positive and within package limits.',
      );
    }
  }
}

final class ScalarRange {
  final double minimum, maximum;
  const ScalarRange._(this.minimum, this.maximum);
}

/// An immutable regular, axis-aligned grid. X varies fastest, then Y, then Z.
/// Null is missing. Zero is valid. NaN and infinity are rejected.
final class ScalarGrid3D {
  final int sizeX, sizeY, sizeZ;
  final Vec3 origin, spacing;
  final ScientificUnit valueUnit, coordinateUnit;
  final ScientificSource source;
  final String name;
  final Float64List _values;
  final Uint8List _valid;
  final ScalarRange? range;
  final int validCount;

  factory ScalarGrid3D({
    required int sizeX,
    required int sizeY,
    required int sizeZ,
    required List<double?> values,
    required Vec3 origin,
    required Vec3 spacing,
    required ScientificUnit valueUnit,
    required ScientificUnit coordinateUnit,
    required ScientificSource source,
    required String name,
    ScientificBudget? budget,
  }) {
    final limits = budget ?? ScientificBudget();
    // Check each factor before multiplying, including maliciously large ints.
    var count = 1;
    for (final size in [sizeX, sizeY, sizeZ]) {
      if (size < 1 || size > limits.maxSamples ~/ count) {
        throw ArgumentError('Grid dimensions exceed the sample budget.');
      }
      count *= size;
    }
    if (values.length != count) {
      throw ArgumentError('Sample count must equal sizeX * sizeY * sizeZ.');
    }
    if (name.trim().isEmpty ||
        name.length > 256 ||
        coordinateUnit.quantity != 'length') {
      throw ArgumentError('A field needs a name and coordinate length unit.');
    }
    if (!origin.isFinite ||
        !spacing.isFinite ||
        spacing.x <= 0 ||
        spacing.y <= 0 ||
        spacing.z <= 0) {
      throw ArgumentError('Origin must be finite and spacing finite/positive.');
    }
    final dimensions = [sizeX, sizeY, sizeZ];
    for (var axis = 0; axis < 3; axis++) {
      final start = origin.storage[axis];
      final step = spacing.storage[axis];
      final end = start + step * (dimensions[axis] - 1);
      if (!end.isFinite ||
          (dimensions[axis] > 1 &&
              (start + step <= start || end - step >= end))) {
        throw ArgumentError('Grid extent exceeds double coordinate precision.');
      }
    }
    double? minimum, maximum;
    var validCount = 0;
    for (final value in values) {
      if (value == null) continue;
      if (!value.isFinite) {
        throw ArgumentError(
          'Use null for missing values; samples must be finite.',
        );
      }
      validCount++;
      if (minimum == null || value < minimum) minimum = value;
      if (maximum == null || value > maximum) maximum = value;
    }
    final data = Float64List(count);
    final valid = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final value = values[i];
      if (value != null) {
        data[i] = value;
        valid[i] = 1;
      }
    }
    return ScalarGrid3D._(
      sizeX,
      sizeY,
      sizeZ,
      origin,
      spacing,
      valueUnit,
      coordinateUnit,
      source,
      name,
      data,
      valid,
      minimum == null ? null : ScalarRange._(minimum, maximum!),
      validCount,
    );
  }

  ScalarGrid3D._(
    this.sizeX,
    this.sizeY,
    this.sizeZ,
    this.origin,
    this.spacing,
    this.valueUnit,
    this.coordinateUnit,
    this.source,
    this.name,
    this._values,
    this._valid,
    this.range,
    this.validCount,
  );

  int get sampleCount => _values.length;
  int get missingCount => sampleCount - validCount;
  int get payloadBytes => _values.lengthInBytes + _valid.lengthInBytes;

  double? valueAt(int x, int y, int z) {
    RangeError.checkValidIndex(x, _values, 'x', sizeX);
    RangeError.checkValidIndex(y, _values, 'y', sizeY);
    RangeError.checkValidIndex(z, _values, 'z', sizeZ);
    final index = x + sizeX * (y + sizeY * z);
    return _valid[index] == 0 ? null : _values[index];
  }
}
