import 'package:gpu3d/gpu3d.dart';
import 'accessor.dart';
import 'checked.dart';
import 'options.dart';
import 'recipes.dart';

final class MaterialDecoder {
  final Map<String, Object?> root;
  final AccessorReader reader;
  final GltfOptions options;
  final List<SceneIssue> issues;
  final images = <int, ImageRecipe>{};
  final _materials = <int, MaterialRecipe>{};
  MaterialDecoder(this.root, this.reader, this.options, this.issues);

  MaterialRecipe read(
    Object? reference,
    String referencePath, {
    required bool present,
  }) {
    final all = array(field(root, 'materials', const []), 'materials');
    final i = present ? index(reference, all.length, referencePath) : -1;
    final cached = _materials[i];
    if (cached != null) return cached;
    final path = i < 0 ? referencePath : 'materials[$i]';
    final material = i < 0 ? <String, Object?>{} : object(all[i], path);
    final extensions = object(
      field(material, 'extensions', <String, Object?>{}),
      '$path.extensions',
    );
    final unlit = extensions.containsKey('KHR_materials_unlit');
    if (unlit) {
      object(
        extensions['KHR_materials_unlit'],
        '$path.extensions.KHR_materials_unlit',
      );
      if (!(root['extensionsUsed'] as List<Object?>? ?? const []).contains(
        'KHR_materials_unlit',
      )) {
        fail(
          '$path.extensions.KHR_materials_unlit',
          'Material extension is absent from extensionsUsed.',
        );
      }
    }
    final standard =
        !unlit && options.materialMode == GltfMaterialMode.standard;
    if (!unlit && !standard) {
      issues.add(
        SceneIssue(
          code: 'gltf.unlitDiagnostic',
          message: 'This PBR material uses an unlit base-color approximation.',
          operation: 'load',
          resourceLabel: path,
          severity: IssueSeverity.warning,
        ),
      );
    }
    final pbr = object(
      field(material, 'pbrMetallicRoughness', <String, Object?>{}),
      '$path.pbrMetallicRoughness',
    );
    final factor = numbers(
      field(pbr, 'baseColorFactor', [1, 1, 1, 1]),
      4,
      '$path.pbrMetallicRoughness.baseColorFactor',
    );
    if (factor.any((v) => v < 0 || v > 1)) {
      fail(
        '$path.pbrMetallicRoughness.baseColorFactor',
        'Base color must be in [0, 1].',
      );
    }
    for (final name in ['metallicFactor', 'roughnessFactor']) {
      final value = number(
        field(pbr, name, 1),
        '$path.pbrMetallicRoughness.$name',
      );
      if (value < 0 || value > 1) {
        fail(
          '$path.pbrMetallicRoughness.$name',
          'Material factors must be in [0, 1].',
        );
      }
    }
    final alpha = string(
      field(material, 'alphaMode', 'OPAQUE'),
      '$path.alphaMode',
    );
    final mode = switch (alpha) {
      'OPAQUE' => MaterialAlphaMode.opaque,
      'MASK' => MaterialAlphaMode.mask,
      'BLEND' => MaterialAlphaMode.blend,
      _ => null,
    };
    if (mode == null) fail('$path.alphaMode', 'Unknown alpha mode.');
    final cutoff = number(
      field(material, 'alphaCutoff', .5),
      '$path.alphaCutoff',
    );
    if (cutoff < 0) {
      fail('$path.alphaCutoff', 'Alpha cutoff must be nonnegative.');
    }
    if (material.containsKey('alphaCutoff') &&
        !material.containsKey('alphaMode')) {
      fail(
        '$path.alphaCutoff',
        'Alpha cutoff requires an explicit alpha mode.',
      );
    }
    if (cutoff > 3.4028234663852886e38) {
      fail(
        '$path.alphaCutoff',
        'Alpha cutoff must fit finite float32 storage.',
      );
    }
    final doubleSided = boolean(
      field(material, 'doubleSided', false),
      '$path.doubleSided',
    );
    final binding = pbr.containsKey('baseColorTexture')
        ? _texture(
            pbr['baseColorTexture'],
            '$path.pbrMetallicRoughness.baseColorTexture',
          )
        : null;
    ImageBindingRecipe? map(
      Map<String, Object?> owner,
      String key,
      String base,
      ColorSpace space,
    ) => standard && owner.containsKey(key)
        ? _texture(owner[key], '$base.$key', colorSpace: space)
        : null;
    final normal = map(material, 'normalTexture', path, ColorSpace.linear);
    final occlusion = map(
      material,
      'occlusionTexture',
      path,
      ColorSpace.linear,
    );
    double textureFactor(String key, String fieldName, double maximum) {
      if (!standard || !material.containsKey(key)) return 1;
      final info = object(material[key], '$path.$key');
      final value = number(field(info, fieldName, 1), '$path.$key.$fieldName');
      if (fieldName == 'strength' && (value < 0 || value > 1)) {
        fail('$path.$key.$fieldName', 'Occlusion strength must be in [0, 1].');
      }
      if (value.abs() > maximum) {
        fail(
          '$path.$key.$fieldName',
          'Texture factor exceeds the native material profile.',
          AssetLoadError.unsupportedFeature,
        );
      }
      return value;
    }

    final emission = standard
        ? numbers(
            field(material, 'emissiveFactor', [0, 0, 0]),
            3,
            '$path.emissiveFactor',
          )
        : [0.0, 0.0, 0.0];
    if (emission.any((v) => v < 0 || v > 1)) {
      fail('$path.emissiveFactor', 'Emissive factors must be in [0, 1].');
    }
    return _materials[i] = MaterialRecipe(
      Color3(factor[0], factor[1], factor[2]),
      factor[3],
      cutoff,
      mode,
      doubleSided ? MaterialSide.doubleSided : MaterialSide.front,
      binding,
      standard: standard,
      metallic: number(
        field(pbr, 'metallicFactor', 1),
        '$path.pbrMetallicRoughness.metallicFactor',
      ),
      roughness: number(
        field(pbr, 'roughnessFactor', 1),
        '$path.pbrMetallicRoughness.roughnessFactor',
      ),
      emissive: Color3(emission[0], emission[1], emission[2]),
      normalMap: normal,
      normalScale: textureFactor('normalTexture', 'scale', 1e6),
      occlusionMap: occlusion,
      occlusionStrength: textureFactor('occlusionTexture', 'strength', 1),
      metallicRoughnessMap: map(
        pbr,
        'metallicRoughnessTexture',
        '$path.pbrMetallicRoughness',
        ColorSpace.linear,
      ),
      emissiveMap: map(material, 'emissiveTexture', path, ColorSpace.srgb),
    );
  }

  ImageBindingRecipe _texture(
    Object? reference,
    String path, {
    ColorSpace colorSpace = ColorSpace.srgb,
  }) {
    final info = object(reference, path);
    final textures = array(field(root, 'textures', const []), 'textures');
    final i = index(info['index'], textures.length, '$path.index');
    final uv = integer(field(info, 'texCoord', 0), '$path.texCoord');
    if (uv > 1) {
      fail(
        '$path.texCoord',
        'Native materials support UV0 and UV1.',
        AssetLoadError.unsupportedFeature,
      );
    }
    final texturePath = 'textures[$i]',
        texture = object(textures[i], 'textures[$i]');
    final sources = array(field(root, 'images', const []), 'images');
    if (!texture.containsKey('source')) {
      fail(
        '$texturePath.source',
        'Texture has no supported image source.',
        AssetLoadError.unsupportedFeature,
      );
    }
    final source = index(
      texture['source'],
      sources.length,
      '$texturePath.source',
    );
    if (!images.containsKey(source)) {
      final imagePath = 'images[$source]',
          image = object(sources[source], 'images[$source]');
      final hasUri = image.containsKey('uri'),
          hasView = image.containsKey('bufferView');
      if (hasUri == hasView) {
        fail(imagePath, 'An image needs exactly one URI or buffer view.');
      }
      final media = image.containsKey('mimeType')
          ? string(image['mimeType'], '$imagePath.mimeType')
          : null;
      if (media != null && media != 'image/png' && media != 'image/jpeg') {
        fail(
          '$imagePath.mimeType',
          'Only PNG and JPEG images are supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      if (hasView && media == null) {
        fail('$imagePath.mimeType', 'Embedded images require a MIME type.');
      }
      final uri = hasUri ? string(image['uri'], '$imagePath.uri') : null;
      if (uri != null && uri.isEmpty) {
        fail('$imagePath.uri', 'Image URI cannot be empty.');
      }
      images[source] = ImageRecipe(
        uri,
        media,
        hasView
            ? reader.imageBytes(image['bufferView'], '$imagePath.bufferView')
            : null,
      );
    }
    var sampler = <String, Object?>{};
    var samplerPath = texturePath;
    if (texture.containsKey('sampler')) {
      final samplers = array(field(root, 'samplers', const []), 'samplers');
      final s = index(
        texture['sampler'],
        samplers.length,
        '$texturePath.sampler',
      );
      samplerPath = 'samplers[$s]';
      sampler = object(samplers[s], samplerPath);
    }
    TextureWrap wrap(String name) {
      final v = integer(field(sampler, name, 10497), '$samplerPath.$name');
      return switch (v) {
        10497 => TextureWrap.repeat,
        33071 => TextureWrap.clampToEdge,
        33648 => TextureWrap.mirroredRepeat,
        _ => fail('$samplerPath.$name', 'Unknown texture wrap mode.'),
      };
    }

    final min = integer(
      field(sampler, 'minFilter', 9987),
      '$samplerPath.minFilter',
    );
    final mag = integer(
      field(sampler, 'magFilter', 9729),
      '$samplerPath.magFilter',
    );
    if (![9728, 9729, 9984, 9985, 9986, 9987].contains(min)) {
      fail('$samplerPath.minFilter', 'Unknown texture minification filter.');
    }
    if (mag != 9728 && mag != 9729) {
      fail('$samplerPath.magFilter', 'Unknown texture magnification filter.');
    }
    return ImageBindingRecipe(
      source,
      uv,
      min >= 9984,
      SamplerDescriptor(
        wrapU: wrap('wrapS'),
        wrapV: wrap('wrapT'),
        minFilter: [9728, 9984, 9986].contains(min)
            ? TextureFilter.nearest
            : TextureFilter.linear,
        magFilter: mag == 9728 ? TextureFilter.nearest : TextureFilter.linear,
        mipFilter: min == 9984 || min == 9985
            ? TextureFilter.nearest
            : TextureFilter.linear,
      ),
      colorSpace: colorSpace,
    );
  }
}
