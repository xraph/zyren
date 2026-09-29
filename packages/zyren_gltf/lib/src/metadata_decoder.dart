import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'accessor.dart';
import 'checked.dart';
import 'metadata.dart';
import 'node_decoder.dart' show numbers;

const structuralMetadataExtension = 'EXT_structural_metadata';

List<ModelPropertyTable> decodePropertyTables(
  Map<String, Object?> root,
  AccessorReader reader,
  DecodeBudget budget,
) {
  final extensions = object(
    field(root, 'extensions', <String, Object?>{}),
    'extensions',
  );
  if (!extensions.containsKey(structuralMetadataExtension)) return const [];
  const path = 'extensions.EXT_structural_metadata';
  if (!array(
    field(root, 'extensionsUsed', const []),
    'extensionsUsed',
  ).contains(structuralMetadataExtension)) {
    fail(path, 'Metadata requires an extensionsUsed declaration.');
  }
  final data = object(extensions[structuralMetadataExtension], path);
  for (final unsupported in [
    'schemaUri',
    'propertyTextures',
    'propertyAttributes',
  ]) {
    if (data.containsKey(unsupported)) {
      fail(
        '$path.$unsupported',
        'This metadata storage profile is not supported.',
        AssetLoadError.unsupportedFeature,
      );
    }
  }
  final schema = object(data['schema'], '$path.schema');
  final classes = object(
    field(schema, 'classes', <String, Object?>{}),
    '$path.schema.classes',
  );
  final enums = object(
    field(schema, 'enums', <String, Object?>{}),
    '$path.schema.enums',
  );
  final tables = array(
    field(data, 'propertyTables', const []),
    '$path.propertyTables',
  );
  final result = <ModelPropertyTable>[];
  for (var t = 0; t < tables.length; t++) {
    final p = '$path.propertyTables[$t]', table = object(tables[t], p);
    final className = string(table['class'], '$p.class');
    final definition = object(classes[className], '$p.class');
    final properties = object(
      field(definition, 'properties', <String, Object?>{}),
      '$p.class.properties',
    );
    final supplied = object(
      field(table, 'properties', <String, Object?>{}),
      '$p.properties',
    );
    final count = integer(table['count'], '$p.count', min: 1);
    if (count > reader.limits.maxObjects ||
        tables.length > reader.limits.maxObjects ||
        properties.length > reader.limits.maxObjects) {
      fail(
        p,
        'Metadata object count exceeds its limit.',
        AssetLoadError.limitExceeded,
      );
    }
    if (supplied.keys.any((key) => !properties.containsKey(key))) {
      fail(p, 'Property is missing from its class.');
    }
    budget.reserve(
      count * (properties.isEmpty ? 1 : properties.length) * 32,
      p,
    );
    final columns = <String, List<Object?>>{};
    for (final entry in properties.entries) {
      final q = '$p.properties.${entry.key}', def = object(entry.value, q);
      final storage = supplied.containsKey(entry.key)
          ? object(supplied[entry.key], q)
          : null;
      final type = string(def['type'], '$q.type');
      if (boolean(field(def, 'array', false), '$q.array')) {
        fail(
          q,
          'Array metadata properties are not yet supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      final components = switch (type) {
        'SCALAR' || 'STRING' || 'BOOLEAN' || 'ENUM' => 1,
        'VEC2' => 2,
        'VEC3' => 3,
        'VEC4' || 'MAT2' => 4,
        'MAT3' => 9,
        'MAT4' => 16,
        _ => fail(q, 'Unknown metadata property type.'),
      };
      final numeric = !['STRING', 'BOOLEAN', 'ENUM'].contains(type);
      Map<int, String>? enumNames;
      var component = numeric
          ? string(def['componentType'], '$q.componentType')
          : '';
      if (type == 'ENUM') {
        final enumType = string(def['enumType'], '$q.enumType');
        final enumeration = object(enums[enumType], '$q.enumType');
        component = string(
          field(enumeration, 'valueType', 'UINT16'),
          '$q.valueType',
        );
        if (component.startsWith('FLOAT')) {
          fail(q, 'Enum storage must use integers.');
        }
        enumNames = {};
        final names = <String>{};
        for (final raw in array(enumeration['values'], '$q.enum.values')) {
          final value = object(raw, q), name = string(value['name'], q);
          final id = integer(
            value['value'],
            q,
            min: -0x80000000,
            max: 0xffffffff,
          );
          if (enumNames.containsKey(id) || !names.add(name)) {
            fail(q, 'Enum names and values must be unique.');
          }
          enumNames[id] = name;
        }
      }
      final normalized = boolean(
        field(def, 'normalized', false),
        '$q.normalized',
      );
      if (normalized && (!numeric || component.startsWith('FLOAT'))) {
        fail(q, 'Only integer numeric properties can be normalized.');
      }
      if (numeric || type == 'ENUM') _componentSize(component, q);
      final required = boolean(field(def, 'required', false), '$q.required');
      if (required &&
          (def.containsKey('default') || def.containsKey('noData'))) {
        fail(q, 'Required properties cannot declare missing values.');
      }
      Object? validateJson(Object? value) {
        if (numeric) {
          final values = components == 1
              ? [number(value, q)]
              : numbers(value, components, q);
          if (!component.startsWith('FLOAT') &&
              values.any((v) => v != v.truncateToDouble())) {
            // Defaults are final values and may be fractional after normalization.
            if (!normalized) {
              fail(q, 'Integer metadata requires integer values.');
            }
          }
          return components == 1
              ? values.single
              : List<Object?>.unmodifiable(values);
        }
        if (type == 'BOOLEAN') return boolean(value, q);
        final text = string(value, q);
        if (type == 'ENUM' && !enumNames!.containsValue(text)) {
          fail(q, 'Unknown enum name.');
        }
        return text;
      }

      final fallback = def.containsKey('default')
          ? validateJson(def['default'])
          : null;
      final noData = def.containsKey('noData')
          ? validateJson(def['noData'])
          : null;
      if (type == 'BOOLEAN' && def.containsKey('noData')) {
        fail(q, 'Boolean properties cannot declare noData.');
      }
      if (storage == null) {
        if (required) fail(q, 'Required property values are missing.');
        columns[entry.key] = List<Object?>.filled(count, fallback);
        continue;
      }
      final size = numeric || type == 'ENUM' ? _componentSize(component, q) : 1;
      final bytes = reader.metadataBytes(storage['values'], size, q);
      final binary = ByteData.sublistView(bytes);
      budget.reserve(count * components * 16, q);
      List<int>? offsets;
      if (type == 'STRING') {
        final offsetType = string(
          field(storage, 'stringOffsetType', 'UINT32'),
          q,
        );
        if (!['UINT8', 'UINT16', 'UINT32'].contains(offsetType)) {
          fail(
            q,
            'Unsupported string offset type.',
            AssetLoadError.unsupportedFeature,
          );
        }
        final width = _componentSize(offsetType, q);
        final offsetBytes = reader.metadataBytes(
          storage['stringOffsets'],
          width,
          q,
        );
        if (offsetBytes.length != (count + 1) * width) {
          fail(q, 'String offsets have the wrong length.');
        }
        final raw = ByteData.sublistView(offsetBytes);
        offsets = [
          for (var i = 0; i <= count; i++)
            _read(raw, i * width, offsetType).toInt(),
        ];
        if (offsets.first != 0 || offsets.last != bytes.length) {
          fail(q, 'String offsets exceed their values.');
        }
        for (var i = 1; i < offsets.length; i++) {
          if (offsets[i] < offsets[i - 1]) {
            fail(q, 'String offsets must be monotonic.');
          }
        }
        budget.reserve(bytes.length * 2 + offsets.length * 8, q);
      } else if (bytes.length !=
          (type == 'BOOLEAN' ? (count + 7) ~/ 8 : count * components * size)) {
        fail(q, 'Property values have the wrong length.');
      }
      List<double> transform(String key, double defaultValue) {
        final value = storage.containsKey(key) ? storage[key] : def[key];
        if (value == null) return List.filled(components, defaultValue);
        if (!numeric || (!normalized && !component.startsWith('FLOAT'))) {
          fail(q, 'Transforms require floating or normalized values.');
        }
        return components == 1
            ? [number(value, q)]
            : numbers(value, components, q);
      }

      final scales = transform('scale', 1), shifts = transform('offset', 0);
      final values = <Object?>[];
      for (var i = 0; i < count; i++) {
        Object value;
        if (type == 'STRING') {
          try {
            value = utf8.decode(
              Uint8List.sublistView(bytes, offsets![i], offsets[i + 1]),
            );
          } on FormatException {
            fail(q, 'Property string contains invalid UTF-8.');
          }
        } else if (type == 'BOOLEAN') {
          value = bytes[i ~/ 8] & (1 << (i % 8)) != 0;
        } else {
          final raw = [
            for (var c = 0; c < components; c++)
              _read(binary, (i * components + c) * size, component),
          ];
          if (raw.any((n) => !n.isFinite)) {
            fail(q, 'Property values must be finite.');
          }
          value = type == 'ENUM'
              ? enumNames![raw.single.toInt()] ?? fail(q, 'Unknown enum value.')
              : components == 1
              ? raw.single
              : raw;
        }
        if (noData != null && _equal(value, noData)) {
          values.add(fallback);
          continue;
        }
        if (numeric) {
          final raw = components == 1
              ? [value as num]
              : (value as List).cast<num>();
          final transformed = [
            for (var c = 0; c < components; c++)
              (normalized ? _normalize(raw[c], component) : raw[c]) *
                      scales[c] +
                  shifts[c],
          ];
          if (transformed.any((n) => !n.isFinite)) {
            fail(q, 'Transformed property values must be finite.');
          }
          value = components == 1
              ? transformed.single
              : List<Object?>.unmodifiable(transformed);
        }
        values.add(value);
      }
      columns[entry.key] = values;
    }
    result.add(
      ModelPropertyTable(
        count: count,
        columns: columns,
        className: className,
        name: table.containsKey('name')
            ? string(table['name'], '$p.name')
            : null,
      ),
    );
  }
  return List.unmodifiable(result);
}

int _componentSize(String type, String path) => switch (type) {
  'INT8' || 'UINT8' => 1,
  'INT16' || 'UINT16' => 2,
  'INT32' || 'UINT32' || 'FLOAT32' => 4,
  'FLOAT64' => 8,
  'INT64' || 'UINT64' => fail(
    path,
    '64-bit integer metadata is not supported.',
    AssetLoadError.unsupportedFeature,
  ),
  _ => fail(path, 'Unknown metadata component type.'),
};
num _read(ByteData b, int at, String type) => switch (type) {
  'INT8' => b.getInt8(at),
  'UINT8' => b.getUint8(at),
  'INT16' => b.getInt16(at, Endian.little),
  'UINT16' => b.getUint16(at, Endian.little),
  'INT32' => b.getInt32(at, Endian.little),
  'UINT32' => b.getUint32(at, Endian.little),
  'FLOAT32' => b.getFloat32(at, Endian.little),
  _ => b.getFloat64(at, Endian.little),
};
double _normalize(num value, String type) {
  final bits = int.parse(type.replaceAll(RegExp('[^0-9]'), ''));
  return type.startsWith('U')
      ? value / (math.pow(2, bits) - 1)
      : math.max(-1.0, value / (math.pow(2, bits - 1) - 1));
}

bool _equal(Object a, Object b) => a is List && b is List
    ? a.length == b.length &&
          List.generate(
            a.length,
            (i) => _equal(a[i] as Object, b[i] as Object),
          ).every((v) => v)
    : a == b;
