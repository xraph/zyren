part of '../../zyren_game_ai.dart';

/// Numeric fields remain in declared units before optional affine normalization.
final class ObservationField {
  final String name, units;
  final int width;
  final double min, max, offset, scale;
  ObservationField(
    this.name, {
    this.units = 'unitless',
    this.width = 1,
    this.min = -1,
    this.max = 1,
    this.offset = 0,
    this.scale = 1,
  }) {
    _name(name);
    _name(units);
    _bounded(width, 65536, 'width');
    if (![min, max, offset, scale].every((v) => v.isFinite) ||
        min >= max ||
        scale <= 0 ||
        !((min - offset) / scale).isFinite ||
        !((max - offset) / scale).isFinite ||
        ((min - offset) / scale).abs() > 3.402823466e38 ||
        ((max - offset) / scale).abs() > 3.402823466e38) {
      throw ArgumentError(
        'Field bounds and normalization must be finite and ordered.',
      );
    }
  }
  Map<String, Object> toJson() => {
    'name': name,
    'units': units,
    'width': width,
    'min': min,
    'max': max,
    'offset': offset,
    'scale': scale,
  };
  bool accepts(double value) => value.isFinite && value >= min && value <= max;
}

final class ObservationSpec {
  final String id, configurationHash;
  final int version, maxEntities, maxRays, cadenceTicks, latencyTicks;
  final List<ObservationField> fields;
  final double range;
  ObservationSpec({
    required this.id,
    this.configurationHash = '',
    this.version = 1,
    required List<ObservationField> fields,
    this.maxEntities = 16,
    this.maxRays = 16,
    this.cadenceTicks = 1,
    this.latencyTicks = 1,
    this.range = 30,
  }) : fields = List.unmodifiable(fields) {
    _name(id);
    if (configurationHash.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(configurationHash)) {
      throw ArgumentError('Invalid configuration hash.');
    }
    _bounded(version, 65535, 'version');
    _bounded(maxEntities, 256, 'maxEntities');
    _bounded(maxRays, 256, 'maxRays', zero: true);
    _bounded(cadenceTicks, 3600, 'cadenceTicks');
    _bounded(latencyTicks, 3600, 'latencyTicks', zero: true);
    if (!range.isFinite ||
        range <= 0 ||
        range > 100000 ||
        fields.isEmpty ||
        fields.length > 128 ||
        fields.map((f) => f.name).toSet().length != fields.length ||
        width > 131072) {
      throw ArgumentError('Invalid observation schema.');
    }
  }
  int get width => fields.fold(0, (sum, f) => sum + f.width);
  String get hash => _hash(toJson());
  Map<String, Object> toJson() => {
    'id': id,
    'configurationHash': configurationHash,
    'version': version,
    'fields': fields.map((f) => f.toJson()).toList(),
    'maxEntities': maxEntities,
    'maxRays': maxRays,
    'range': range,
    'cadenceTicks': cadenceTicks,
    'latencyTicks': latencyTicks,
  };
}
