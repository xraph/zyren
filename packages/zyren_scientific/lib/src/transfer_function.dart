import 'package:zyren/zyren.dart';

import 'scalar_grid.dart';

/// RGB channels are linear values in [0, 1]. Stops span normalized [0, 1].
final class TransferStop {
  final double position;
  final Color3 color;

  TransferStop(this.position, this.color) {
    if (!position.isFinite ||
        position < 0 ||
        position > 1 ||
        color.toList().any((channel) => channel < 0 || channel > 1)) {
      throw ArgumentError(
        'Transfer positions and linear RGB must be in [0, 1].',
      );
    }
  }
}

/// Piecewise linear RGB mapping with explicit unit and clamped endpoints.
/// A constant range maps to the midpoint. Missing samples have no color.
final class ScalarTransferFunction {
  final ScientificUnit unit;
  final double minimum, maximum;
  final List<TransferStop> stops;

  ScalarTransferFunction({
    required this.unit,
    required this.minimum,
    required this.maximum,
    required List<TransferStop> stops,
  }) : stops = List.unmodifiable(stops) {
    if (!minimum.isFinite ||
        !maximum.isFinite ||
        maximum < minimum ||
        !(maximum - minimum).isFinite) {
      throw ArgumentError('Transfer range must be finite and ordered.');
    }
    if (stops.length < 2 ||
        stops.length > 256 ||
        stops.first.position != 0 ||
        stops.last.position != 1) {
      throw ArgumentError('Use 2 to 256 stops, including positions 0 and 1.');
    }
    for (var i = 1; i < stops.length; i++) {
      if (stops[i].position <= stops[i - 1].position) {
        throw ArgumentError('Transfer positions must increase strictly.');
      }
    }
  }

  Color3? map(double? value) {
    if (value == null) return null;
    if (!value.isFinite) throw ArgumentError('Transfer input must be finite.');
    final double position;
    if (minimum == maximum) {
      position = .5;
    } else if (value <= minimum) {
      position = 0;
    } else if (value >= maximum) {
      position = 1;
    } else {
      position = (value - minimum) / (maximum - minimum);
    }
    for (var i = 1; i < stops.length; i++) {
      final right = stops[i];
      if (position > right.position) continue;
      final left = stops[i - 1];
      final t = (position - left.position) / (right.position - left.position);
      return Color3(
        left.color.r * (1 - t) + right.color.r * t,
        left.color.g * (1 - t) + right.color.g * t,
        left.color.b * (1 - t) + right.color.b * t,
      );
    }
    return stops.last.color;
  }
}
