import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'checked.dart';
import 'recipes.dart';

const _extension = 'KHR_lights_punctual';

final class LightDecoder {
  final Map<String, Object?> root;
  late final List<LightRecipe> lights;
  LightDecoder(this.root) {
    lights = _read();
  }

  Map<String, Object?>? _extensionOf(Map<String, Object?> owner, String path) {
    final extensions = object(
      field(owner, 'extensions', <String, Object?>{}),
      '${path}extensions',
    );
    if (!extensions.containsKey(_extension)) return null;
    if (!(root['extensionsUsed'] as List<Object?>? ?? const []).contains(
      _extension,
    )) {
      fail(
        '${path}extensions.$_extension',
        'Light extension is absent from extensionsUsed.',
      );
    }
    return object(extensions[_extension], '${path}extensions.$_extension');
  }

  List<LightRecipe> _read() {
    final extension = _extensionOf(root, '');
    if (extension == null) return const [];
    const path = 'extensions.$_extension.lights';
    final values = array(extension['lights'], path);
    if (values.isEmpty) {
      fail(path, 'Light arrays must be nonempty when present.');
    }
    return [
      for (var i = 0; i < values.length; i++)
        _light(object(values[i], '$path[$i]'), '$path[$i]'),
    ];
  }

  LightRecipe? forNode(Map<String, Object?> node, String path) {
    final extension = _extensionOf(node, '$path.');
    if (extension == null) return null;
    return lights[index(
      extension['light'],
      lights.length,
      '$path.extensions.$_extension.light',
    )];
  }

  LightRecipe _light(Map<String, Object?> value, String path) {
    final type = string(value['type'], '$path.type');
    if (!['directional', 'point', 'spot'].contains(type)) {
      fail('$path.type', 'Unknown punctual light type.');
    }
    final color = numbers(field(value, 'color', [1, 1, 1]), 3, '$path.color');
    if (color.any((v) => v < 0 || v > 1)) {
      fail('$path.color', 'Light color must be in [0, 1].');
    }
    final intensity = number(field(value, 'intensity', 1), '$path.intensity');
    if (intensity < 0) {
      fail('$path.intensity', 'Light intensity must be nonnegative.');
    }
    if (intensity > 1e12) {
      fail(
        '$path.intensity',
        'Light intensity exceeds the native profile.',
        AssetLoadError.unsupportedFeature,
      );
    }
    double? range;
    if (value.containsKey('range')) {
      range = number(value['range'], '$path.range');
      if (range <= 0) fail('$path.range', 'Light range must be positive.');
      if (range > 1e12 || Float32List.fromList([range]).single == 0) {
        fail(
          '$path.range',
          'Light range exceeds the native profile.',
          AssetLoadError.unsupportedFeature,
        );
      }
      if (type == 'directional') {
        fail('$path.range', 'Range requires a point or spot light.');
      }
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
      if (inner < 0 || inner >= math.pi / 2) {
        fail(
          '$path.spot.innerConeAngle',
          'Inner cone angle must be in [0, pi/2).',
        );
      }
      if (outer <= inner || outer > math.pi / 2) {
        fail(
          '$path.spot.outerConeAngle',
          'Outer cone angle must be greater than inner and at most pi/2.',
        );
      }
    } else if (value.containsKey('spot')) {
      fail('$path.spot', 'Spot properties require a spot light.');
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
}
