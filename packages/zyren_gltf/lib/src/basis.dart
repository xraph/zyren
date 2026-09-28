import 'checked.dart';

const basisExtension = 'KHR_texture_basisu';

Map<String, Object?> selectBasisTextures(
  Map<String, Object?> root,
  bool supported,
) {
  final textures = array(field(root, 'textures', const []), 'textures');
  final images = array(field(root, 'images', const []), 'images');
  final required = array(
    field(root, 'extensionsRequired', const []),
    'extensionsRequired',
  ).contains(basisExtension);
  final used = array(
    field(root, 'extensionsUsed', const []),
    'extensionsUsed',
  ).contains(basisExtension);
  return {
    ...root,
    'textures': [
      for (var i = 0; i < textures.length; i++)
        (() {
          final path = 'textures[$i]';
          final texture = object(textures[i], path);
          final extensions = object(
            field(texture, 'extensions', <String, Object?>{}),
            '$path.extensions',
          );
          if (!extensions.containsKey(basisExtension)) return texture;
          if (!supported) {
            return {
              ...texture,
              'extensions': {...extensions}..remove(basisExtension),
            };
          }
          final extPath = '$path.extensions.$basisExtension';
          if (!used) {
            fail(extPath, 'Basis textures must be declared in extensionsUsed.');
          }
          final ext = object(extensions[basisExtension], extPath);
          if (!texture.containsKey('source') && !required) {
            fail(
              extPath,
              'A Basis texture without fallback must require KHR_texture_basisu.',
            );
          }
          return {
            ...texture,
            'source': index(ext['source'], images.length, '$extPath.source'),
          };
        })(),
    ],
  };
}
