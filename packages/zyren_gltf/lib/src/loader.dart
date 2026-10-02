import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'buffers.dart';
import 'basis.dart';
import 'draco.dart';
import 'meshopt.dart';
import 'animation_decoder.dart';
import 'data_uri.dart';
import 'options.dart';
import 'recipes.dart';
import 'material_decoder.dart' show physicalExtensions, emissionExtension;
import 'worker.dart';
import 'features.dart';
import 'metadata.dart';
import 'metadata_decoder.dart' show structuralMetadataExtension;
part 'model_asset.dart';

abstract final class Gltf {
  static AssetRequest<ModelAsset> asset(
    String path, {
    GltfOptions options = const GltfOptions(),
    String? version,
  }) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        path,
        'path',
        'Use a relative bundle path without traversal segments.',
      );
    }
    return uri(
      Uri(scheme: 'asset', host: '', path: '/$path'),
      options: options,
      version: version,
    );
  }

  static AssetRequest<ModelAsset> uri(
    Uri uri, {
    GltfOptions options = const GltfOptions(),
    String? version,
  }) {
    options.limits.validate();
    return AssetRequest(
      uri: uri,
      loader: _GltfLoader(options),
      version: version,
    );
  }
}

final class _GltfLoader extends AssetLoader<ModelAsset> {
  final GltfOptions options;
  const _GltfLoader(this.options);
  @override
  Object get cacheKey => options;
  @override
  Future<DecodedAsset<ModelAsset>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    try {
      context.report(LoadProgress(stage: LoadStage.decode, completedBytes: 0));
      final document = await GltfWorkers.parse(
        source.bytes,
        options.limits,
        context.cancellation,
        supportedExtensions: {
          'KHR_materials_unlit',
          'EXT_mesh_features',
          structuralMetadataExtension,
          ...physicalExtensions,
          emissionExtension,
          'KHR_lights_punctual',
          if (context.supportsTextureEncoding(TextureEncoding.ktx2Basis))
            basisExtension,
          if (context.supportsMeshEncoding(MeshEncoding.draco)) dracoExtension,
          if (context.supportsBufferEncoding(BufferEncoding.meshopt))
            meshoptExtension,
        },
      );
      final meshopt = context.supportsBufferEncoding(BufferEncoding.meshopt)
          ? MeshoptViews.inspect(document)
          : null;
      var buffers = await resolveBuffers(
        document,
        context,
        source.effectiveUri,
        skippedBuffers: meshopt?.skippedBuffers ?? const {},
      );
      var root = document.root;
      if (meshopt != null) {
        (root, buffers) = await meshopt.decode(document, buffers, context);
      }
      if (context.supportsMeshEncoding(MeshEncoding.draco)) {
        (root, buffers) = await decodeDraco(
          root,
          buffers,
          context,
          options.limits,
        );
      }
      root = selectBasisTextures(
        root,
        context.supportsTextureEncoding(TextureEncoding.ktx2Basis),
      );
      final prepared = await GltfWorkers.model(
        root,
        buffers,
        options,
        context.limits.maxDecodedBytes - context.decodedBytes,
        context.cancellation,
      );
      context.reserveDecodedBytes(prepared.decodedBytes);
      final variants = <int, Set<(bool, ColorSpace)>>{};
      for (final mesh in prepared.meshes) {
        for (final primitive in mesh) {
          for (final binding in primitive.material.maps) {
            (variants[binding.source] ??= <(bool, ColorSpace)>{}).add((
              binding.mipmaps,
              binding.colorSpace,
            ));
          }
        }
      }
      final images = <(int, bool, ColorSpace), TextureImage>{};
      for (final entry in prepared.images.entries) {
        context.cancellation.throwIfCancelled();
        final path = 'images[${entry.key}]', recipe = entry.value;
        Uint8List bytes;
        var imageUri = source.effectiveUri;
        var media = recipe.mediaType;
        if (recipe.bytes case final embedded?) {
          bytes = embedded;
        } else if (isDataUri(recipe.uri!)) {
          bytes = await GltfWorkers.dataUri(
            recipe.uri!,
            math.min(
              context.limits.images.maxEncodedBytes,
              context.limits.maxDecodedBytes - context.decodedBytes,
            ),
            recipe.basis
                ? const {'image/ktx2'}
                : const {'image/png', 'image/jpeg'},
            context.cancellation,
            '$path.uri',
          );
          context.reserveDecodedBytes(bytes.length, fieldPath: '$path.uri');
          media ??= recipe.uri!
              .substring(5, recipe.uri!.indexOf(';'))
              .toLowerCase();
        } else {
          final imageSource = await context.readReference(
            recipe.uri!,
            relativeTo: source.effectiveUri,
            fieldPath: '$path.uri',
          );
          bytes = imageSource.bytes;
          imageUri = imageSource.effectiveUri;
        }
        _checkImageType(bytes, media, path, imageUri, basis: recipe.basis);
        if (recipe.basis) {
          final texture = await context.decodeTexture(
            bytes,
            encoding: TextureEncoding.ktx2Basis,
            fieldPath: path,
          );
          for (final (mipmaps, colorSpace) in variants[entry.key]!) {
            final expected = texture.descriptor.format.withSrgb(
              colorSpace == ColorSpace.srgb,
            );
            if (texture.descriptor.format != expected) {
              throw AssetLoadException(
                AssetLoadError.invalidData,
                'Basis transfer function does not match the material texture usage.',
                sourceUri: imageUri,
                fieldPath: path,
              );
            }
            final unchanged = mipmaps
                ? (texture.levels.length > 1 ||
                      texture.descriptor.format.isCompressed)
                : texture.levels.length == 1;
            final selected = mipmaps ? texture.levels : [texture.levels.first];
            if (!unchanged) {
              context.reserveDecodedBytes(
                selected.fold<int>(0, (sum, level) => sum + level.length),
                fieldPath: path,
              );
            }
            final data = unchanged
                ? texture
                : await GltfWorkers.texture(
                    texture,
                    mipmaps,
                    context.cancellation,
                  );
            images[(entry.key, mipmaps, colorSpace)] = TextureImage.fromData(
              data,
            );
          }
          continue;
        }
        final image = await context.decodeImage(bytes, fieldPath: path);
        for (final (mipmaps, colorSpace) in variants[entry.key]!) {
          context.reserveDecodedBytes(
            image.size.width * image.size.height * 4,
            fieldPath: path,
          );
          final data = await GltfWorkers.image(
            image,
            mipmaps,
            context.cancellation,
            colorSpace: colorSpace,
          );
          images[(entry.key, mipmaps, colorSpace)] = TextureImage.fromData(
            data,
          );
        }
      }
      context.report(LoadProgress(stage: LoadStage.prepare, completedBytes: 0));
      final meshes = <List<_ModelPrimitive>>[];
      var published = 0;
      for (final mesh in prepared.meshes) {
        final primitives = <_ModelPrimitive>[];
        for (final primitive in mesh) {
          context.cancellation.throwIfCancelled();
          var data = primitive.geometry;
          final m = primitive.material;
          final tangentMap =
              m.normalMap ?? m.physical?.maps[2] ?? m.physical?.maps[7];
          final needsTangent =
              tangentMap != null || (m.physical?.factors.anisotropy ?? 0) > 0;
          if (needsTangent &&
              !data.attributes.containsKey(VertexSemantic.tangent)) {
            data = await context.generateTangents(
              data,
              uvSet: tangentMap?.uvSet ?? 0,
              fieldPath:
                  'meshes[${meshes.length}].primitives[${primitives.length}].attributes.TANGENT',
            );
          }
          final geometry = BufferGeometry.fromData(data);
          TextureMap? texture(ImageBindingRecipe? binding) => binding == null
              ? null
              : TextureMap(
                  image:
                      images[(
                        binding.source,
                        binding.mipmaps,
                        binding.colorSpace,
                      )]!,
                  sampler: binding.sampler,
                  uvSet: binding.uvSet,
                );
          final map = texture(m.colorMap);
          final vertexColors = geometry.attributes.containsKey(
            VertexSemantic.color,
          );
          MeshMaterial material = switch (geometry.topology) {
            GeometryTopology.triangles when m.standard => StandardMaterial(
              baseColor: m.color,
              baseColorMap: map,
              metallic: m.metallic,
              roughness: m.roughness,
              normalMap: texture(m.normalMap),
              normalScale: m.normalScale,
              metallicRoughnessMap: texture(m.metallicRoughnessMap),
              occlusionMap: texture(m.occlusionMap),
              occlusionStrength: m.occlusionStrength,
              emissive: m.emissive,
              emissiveIntensity: m.emissiveIntensity,
              emissiveMap: texture(m.emissiveMap),
              side: m.side,
              opacity: m.opacity,
              vertexColors: vertexColors,
              alphaMode: m.alphaMode,
              alphaCutoff: m.cutoff,
            ),
            GeometryTopology.triangles => UnlitMaterial(
              color: m.color,
              colorMap: texture(m.colorMap),
              side: m.side,
              opacity: m.opacity,
              vertexColors: vertexColors,
              alphaMode: m.alphaMode,
              alphaCutoff: m.cutoff,
            ),
            GeometryTopology.points => PointsMaterial(
              color: m.color,
              size: 1,
              shape: PointShape.square,
              opacity: m.opacity,
              vertexColors: vertexColors,
              alphaMode: m.alphaMode,
              alphaCutoff: m.cutoff,
            ),
            _ => LineMaterial(
              color: m.color,
              width: 1,
              opacity: m.opacity,
              vertexColors: vertexColors,
              alphaMode: m.alphaMode,
              alphaCutoff: m.cutoff,
            ),
          };
          if (m.physical case final physical?) {
            if (geometry.topology != GeometryTopology.triangles) {
              throw AssetLoadException(
                AssetLoadError.unsupportedFeature,
                'Physical glTF materials require triangle primitives.',
                fieldPath:
                    'meshes[${meshes.length}].primitives[${primitives.length}]',
              );
            }
            final maps = physical.maps.map(texture).toList();
            material = physical.factors.copyWith(
              baseColor: m.color,
              baseColorMap: map,
              metallic: m.metallic,
              roughness: m.roughness,
              normalMap: texture(m.normalMap),
              normalScale: m.normalScale,
              metallicRoughnessMap: texture(m.metallicRoughnessMap),
              occlusionMap: texture(m.occlusionMap),
              occlusionStrength: m.occlusionStrength,
              emissive: m.emissive,
              emissiveIntensity: m.emissiveIntensity,
              emissiveMap: texture(m.emissiveMap),
              side: m.side,
              opacity: m.opacity,
              vertexColors: vertexColors,
              alphaMode: m.alphaMode,
              alphaCutoff: m.cutoff,
              clearcoatMap: maps[0],
              clearcoatRoughnessMap: maps[1],
              clearcoatNormalMap: maps[2],
              sheenColorMap: maps[3],
              sheenRoughnessMap: maps[4],
              specularIntensityMap: maps[5],
              specularColorMap: maps[6],
              anisotropyMap: maps[7],
              transmissionMap: maps[8],
              thicknessMap: maps[9],
              iridescenceMap: maps[10],
              iridescenceThicknessMap: maps[11],
            );
          }
          primitives.add(
            _ModelPrimitive(
              geometry,
              material,
              primitive.name,
              primitive.features,
            ),
          );
          if (++published % 64 == 0) await Future<void>.delayed(Duration.zero);
        }
        meshes.add(List.unmodifiable(primitives));
      }
      context.cancellation.throwIfCancelled();
      final issues = List<SceneIssue>.unmodifiable([
        for (final issue in [...document.issues, ...prepared.issues])
          SceneIssue(
            code: issue.code,
            message: issue.message,
            operation: issue.operation,
            severity: issue.severity,
            sourceUri: source.effectiveUri,
            resourceLabel: issue.resourceLabel,
          ),
      ]);
      final copyright =
          (document.root['asset'] as Map<String, Object?>)['copyright']
              as String?;
      context.reserveDecodedBytes((copyright?.length ?? 0) * 2);
      final shared = _SharedModel(
        prepared.skins,
        prepared.animations,
        prepared.nodes,
        prepared.scenes,
        prepared.defaultScene,
        List.unmodifiable(meshes),
        issues,
        source.effectiveUri,
        copyright,
        prepared.propertyTables,
      );
      return DecodedAsset(
        create: () => ModelAsset._(shared),
        release: _releaseModel,
      );
    } on AssetLoadException catch (error) {
      throw AssetLoadException(
        error.code,
        error.issue.message,
        sourceUri: error.issue.sourceUri ?? source.effectiveUri,
        fieldPath: error.fieldPath,
        cause: error,
      );
    }
  }
}

void _releaseModel(ModelAsset asset) => asset._release();

void _checkImageType(
  Uint8List bytes,
  String? media,
  String path,
  Uri uri, {
  bool basis = false,
}) {
  if (basis) {
    const magic = [171, 75, 84, 88, 32, 50, 48, 187, 13, 10, 26, 10];
    if (bytes.length < magic.length ||
        Iterable<int>.generate(magic.length).any((i) => bytes[i] != magic[i]) ||
        (media != null && media != 'image/ktx2')) {
      throw AssetLoadException(
        AssetLoadError.invalidData,
        'Basis sources require KTX2 bytes and MIME type.',
        sourceUri: uri,
        fieldPath: path,
      );
    }
    return;
  }
  final png =
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10;
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  if ((media == 'image/png' && !png) || (media == 'image/jpeg' && !jpeg)) {
    throw AssetLoadException(
      AssetLoadError.invalidData,
      'Image bytes do not match the declared MIME type.',
      sourceUri: uri,
      fieldPath: '$path.mimeType',
    );
  }
  if (!png && !jpeg) {
    throw AssetLoadException(
      AssetLoadError.unsupportedFeature,
      'Only PNG and JPEG image sources are supported.',
      sourceUri: uri,
      fieldPath: path,
    );
  }
}
