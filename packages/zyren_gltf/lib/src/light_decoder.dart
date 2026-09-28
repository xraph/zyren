import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'recipes.dart';

List<LightRecipe> decodeLights(Map<String, Object?> root, int limit) {
  final extensions = object(
    field(root, 'extensions', <String, Object?>{}),
    'extensions',
  );
  if (!extensions.containsKey('KHR_lights_punctual')) return const [];
  const path = 'extensions.KHR_lights_punctual';
  requireLightExtension(root, path);
  final raw = array(
    object(extensions['KHR_lights_punctual'], path)['lights'],
    '$path.lights',
  );
  if (raw.isEmpty || raw.length > limit) {
    fail(
      '$path.lights',
      'Light definitions exceed the bounded profile.',
      AssetLoadError.limitExceeded,
    );
  }
  return [
    for (var i = 0; i < raw.length; i++)
      _light(object(raw[i], '$path.lights[$i]'), '$path.lights[$i]'),
  ];
}

void requireLightExtension(Map<String, Object?> root, String path) {
  if (!(root['extensionsUsed'] as List<Object?>? ?? const []).contains(
    'KHR_lights_punctual',
  )) {
    fail(path, 'Light extension is absent from extensionsUsed.');
  }
}

LightRecipe _light(Map<String, Object?> value, String path) {
  final type = string(value['type'], '$path.type');
  if (!{'directional', 'point', 'spot'}.contains(type)) {
    fail('$path.type', 'Unknown punctual light type.');
  }
  final raw = array(field(value, 'color', [1, 1, 1]), '$path.color');
  if (raw.length != 3) fail('$path.color', 'Expected three color channels.');
  final color = [for (var i = 0; i < 3; i++) number(raw[i], '$path.color[$i]')];
  if (color.any((v) => v < 0 || v > 1)) {
    fail('$path.color', 'Light color must be in [0, 1].');
  }
  final intensity = number(field(value, 'intensity', 1), '$path.intensity');
  if (intensity < 0 || intensity > 1e12) {
    fail('$path.intensity', 'Light intensity exceeds the native range.');
  }
  final range = value.containsKey('range')
      ? number(value['range'], '$path.range')
      : 0.0;
  if (value.containsKey('range') &&
      (type == 'directional' || range <= 0 || range > 1e12)) {
    fail(
      '$path.range',
      'Range must be positive and belongs to point or spot lights.',
    );
  }
  var inner = 0.0, outer = math.pi / 4;
  if (type == 'spot') {
    final spot = object(value['spot'], '$path.spot');
    inner = number(
      field(spot, 'innerConeAngle', 0),
      '$path.spot.innerConeAngle',
    );
    outer = number(
      field(spot, 'outerConeAngle', math.pi / 4),
      '$path.spot.outerConeAngle',
    );
    if (inner < 0 || inner >= outer || outer > math.pi / 2) {
      fail('$path.spot', 'Spot cones require 0 <= inner < outer <= pi/2.');
    }
  } else if (value.containsKey('spot')) {
    fail('$path.spot', 'Spot parameters require a spot light.');
  }
  return LightRecipe(
    type,
    value.containsKey('name') ? string(value['name'], '$path.name') : null,
    Color3(color[0], color[1], color[2]),
    intensity,
    range,
    inner,
    outer,
  );
}
