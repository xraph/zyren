part of 'material_decoder.dart';

const physicalExtensions = {
  'KHR_materials_ior',
  'KHR_materials_specular',
  'KHR_materials_clearcoat',
  'KHR_materials_sheen',
  'KHR_materials_anisotropy',
  'KHR_materials_transmission',
  'KHR_materials_volume',
};
const emissionExtension = 'KHR_materials_emissive_strength';

extension on MaterialDecoder {
  PhysicalRecipe? _physical(
    Map<String, Object?> extensions,
    String path,
    bool standard,
    bool unlit,
  ) {
    if (!physicalExtensions.any(extensions.containsKey)) return null;
    final parsed = <String, Map<String, Object?>>{};
    for (final name in physicalExtensions) {
      if (!extensions.containsKey(name)) continue;
      final where = '$path.extensions.$name';
      if (!(root['extensionsUsed'] as List<Object?>? ?? const []).contains(
        name,
      )) {
        fail(where, 'Material extension is absent from extensionsUsed.');
      }
      if (unlit) {
        fail(
          where,
          'Physical layers cannot be combined with KHR_materials_unlit.',
        );
      }
      parsed[name] = object(extensions[name], where);
    }
    Map<String, Object?> ext(String name) =>
        parsed['KHR_materials_$name'] ?? const {};
    String location(String name, String key) =>
        '$path.extensions.KHR_materials_$name.$key';
    double factor(
      String name,
      String key,
      double fallback, {
      double minimum = 0,
      double maximum = 1,
    }) {
      final value = number(
        field(ext(name), key, fallback),
        location(name, key),
      );
      if (value < minimum || value > maximum) {
        fail(
          location(name, key),
          'Value exceeds the native physical material profile.',
          AssetLoadError.unsupportedFeature,
        );
      }
      return value;
    }

    Color3 color(
      String name,
      String key,
      List<double> fallback, {
      double maximum = 1,
    }) {
      final values = numbers(
        field(ext(name), key, fallback),
        3,
        location(name, key),
      );
      if (values.any((v) => v < 0 || v > maximum)) {
        fail(
          location(name, key),
          'Physical color factors exceed the native profile.',
        );
      }
      return Color3(values[0], values[1], values[2]);
    }

    ImageBindingRecipe? map(String name, String key, {bool srgb = false}) =>
        standard && ext(name).containsKey(key)
        ? _texture(
            ext(name)[key],
            location(name, key),
            colorSpace: srgb ? ColorSpace.srgb : ColorSpace.linear,
          )
        : null;
    var normalScale = 1.0;
    if (ext('clearcoat').containsKey('clearcoatNormalTexture')) {
      final where = location('clearcoat', 'clearcoatNormalTexture');
      final info = object(ext('clearcoat')['clearcoatNormalTexture'], where);
      normalScale = number(field(info, 'scale', 1), '$where.scale');
      if (normalScale.abs() > 1e6) {
        fail(
          '$where.scale',
          'Normal scale exceeds the native profile.',
          AssetLoadError.unsupportedFeature,
        );
      }
    }
    final ior = factor('ior', 'ior', 1.5, maximum: 1e6);
    if (ior != 0 && ior < 1) {
      fail(location('ior', 'ior'), 'IOR must be zero or at least one.');
    }
    final distance = ext('volume').containsKey('attenuationDistance')
        ? factor(
            'volume',
            'attenuationDistance',
            1,
            minimum: 1e-6,
            maximum: 1e12,
          )
        : double.infinity;
    final factors = PhysicalMaterial(
      transmission: factor('transmission', 'transmissionFactor', 0),
      thickness: factor('volume', 'thicknessFactor', 0, maximum: 1e6),
      attenuationDistance: distance,
      attenuationColor: color('volume', 'attenuationColor', [1, 1, 1]),
      ior: ior,
      specularIntensity: factor('specular', 'specularFactor', 1),
      specularColor: color('specular', 'specularColorFactor', [
        1,
        1,
        1,
      ], maximum: 1e6),
      clearcoat: factor('clearcoat', 'clearcoatFactor', 0),
      clearcoatRoughness: factor('clearcoat', 'clearcoatRoughnessFactor', 0),
      clearcoatNormalScale: normalScale,
      sheenColor: color('sheen', 'sheenColorFactor', [0, 0, 0]),
      sheenRoughness: factor('sheen', 'sheenRoughnessFactor', 0),
      anisotropy: factor('anisotropy', 'anisotropyStrength', 0),
      anisotropyRotation: factor(
        'anisotropy',
        'anisotropyRotation',
        0,
        minimum: -1e6,
        maximum: 1e6,
      ),
    );
    final recipe = PhysicalRecipe(factors, [
      map('clearcoat', 'clearcoatTexture'),
      map('clearcoat', 'clearcoatRoughnessTexture'),
      map('clearcoat', 'clearcoatNormalTexture'),
      map('sheen', 'sheenColorTexture', srgb: true),
      map('sheen', 'sheenRoughnessTexture'),
      map('specular', 'specularTexture'),
      map('specular', 'specularColorTexture', srgb: true),
      map('anisotropy', 'anisotropyTexture'),
      map('transmission', 'transmissionTexture'),
      map('volume', 'thicknessTexture'),
    ]);
    return standard ? recipe : null;
  }

  double _emissionStrength(
    Map<String, Object?> extensions,
    String path,
    bool unlit,
  ) {
    if (!extensions.containsKey(emissionExtension)) return 1;
    final where = '$path.extensions.$emissionExtension';
    if (!(root['extensionsUsed'] as List<Object?>? ?? const []).contains(
      emissionExtension,
    )) {
      fail(where, 'Material extension is absent from extensionsUsed.');
    }
    if (unlit) {
      fail(
        where,
        'Emissive strength cannot be combined with KHR_materials_unlit.',
      );
    }
    final extension = object(extensions[emissionExtension], where);
    final strength = number(
      field(extension, 'emissiveStrength', 1),
      '$where.emissiveStrength',
    );
    if (strength < 0 || strength > 1e12) {
      fail(
        '$where.emissiveStrength',
        'Emission strength exceeds the native profile.',
        AssetLoadError.unsupportedFeature,
      );
    }
    return strength;
  }
}
