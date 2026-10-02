/// Immutable column storage shared by all instances of a model.
final class ModelPropertyTable {
  final int count;
  final String? className, name;
  final Map<String, List<Object?>> _columns;
  ModelPropertyTable({
    required this.count,
    required Map<String, List<Object?>> columns,
    this.className,
    this.name,
  }) : _columns = Map.unmodifiable({
         for (final entry in columns.entries)
           entry.key: List<Object?>.unmodifiable(entry.value.map(_freeze)),
       }) {
    if (count < 0 || _columns.values.any((values) => values.length != count)) {
      throw ArgumentError('Property columns must match the table count.');
    }
  }
  Iterable<String> get propertyNames => _columns.keys;
  Map<String, Object?> properties(int featureId) {
    RangeError.checkValueInInterval(featureId, 0, count - 1, 'featureId');
    return Map.unmodifiable({
      for (final e in _columns.entries) e.key: e.value[featureId],
    });
  }
}

Object? _freeze(Object? value) => switch (value) {
  List values => List<Object?>.unmodifiable(values.map(_freeze)),
  Map<String, Object?> values => Map<String, Object?>.unmodifiable({
    for (final e in values.entries) e.key: _freeze(e.value),
  }),
  null || String() || bool() || num() => value,
  _ => throw ArgumentError('Metadata values must be JSON values.'),
};
