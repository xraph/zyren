import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'features.dart';
import 'metadata.dart';

final class PreparedModel {
  final List<NodeRecipe> nodes;
  final List<SceneRecipe> scenes;
  final int? defaultScene;
  final List<List<PrimitiveRecipe>> meshes;
  final Map<int, ImageRecipe> images;
  final List<SceneIssue> issues;
  final int decodedBytes;
  final List<ModelPropertyTable> propertyTables;
  const PreparedModel(
    this.nodes,
    this.scenes,
    this.defaultScene,
    this.meshes,
    this.images,
    this.issues,
    this.decodedBytes,
    this.propertyTables,
  );
}

final class NodeRecipe {
  final String? name;
  final Vec3 position, scale;
  final Quat rotation;
  final int? mesh;
  final List<int> children;
  final LightRecipe? light;
  const NodeRecipe(
    this.name,
    this.position,
    this.rotation,
    this.scale,
    this.mesh,
    this.children,
    this.light,
  );
}

final class SceneRecipe {
  final String? name;
  final List<int> roots;
  const SceneRecipe(this.name, this.roots);
}

final class PrimitiveRecipe {
  final GeometryData geometry;
  final MaterialRecipe material;
  final String? name;
  final List<ModelFeature> features;
  const PrimitiveRecipe(
    this.geometry,
    this.material,
    this.name, {
    this.features = const [],
  });
}

final class MaterialRecipe {
  final Color3 color;
  final double opacity, cutoff;
  final MaterialAlphaMode alphaMode;
  final MaterialSide side;
  final ImageBindingRecipe? colorMap;
  final bool standard;
  final double metallic, roughness, normalScale, occlusionStrength;
  final Color3 emissive;
  final ImageBindingRecipe? normalMap,
      metallicRoughnessMap,
      occlusionMap,
      emissiveMap;
  Iterable<ImageBindingRecipe> get maps => [
    colorMap,
    normalMap,
    metallicRoughnessMap,
    occlusionMap,
    emissiveMap,
  ].nonNulls;
  const MaterialRecipe(
    this.color,
    this.opacity,
    this.cutoff,
    this.alphaMode,
    this.side,
    this.colorMap, {
    this.standard = false,
    this.metallic = 1,
    this.roughness = 1,
    this.normalScale = 1,
    this.occlusionStrength = 1,
    this.emissive = const Color3(0, 0, 0),
    this.normalMap,
    this.metallicRoughnessMap,
    this.occlusionMap,
    this.emissiveMap,
  });
}

final class ImageBindingRecipe {
  final int source, uvSet;
  final bool mipmaps, linear;
  final SamplerDescriptor sampler;
  const ImageBindingRecipe(
    this.source,
    this.uvSet,
    this.mipmaps,
    this.sampler, {
    this.linear = false,
  });
}

final class ImageRecipe {
  final String? uri, mediaType;
  final Uint8List? bytes;
  final bool basis;
  const ImageRecipe(this.uri, this.mediaType, this.bytes, {this.basis = false});
}

final class LightRecipe {
  final String kind;
  final String? name;
  final Color3 color;
  final double intensity, range, inner, outer;
  const LightRecipe(
    this.kind,
    this.name,
    this.color,
    this.intensity,
    this.range,
    this.inner,
    this.outer,
  );
  Light instantiate() => switch (kind) {
    'directional' => DirectionalLight(
      name: name,
      color: color,
      intensity: intensity,
    ),
    'point' => PointLight(
      name: name,
      color: color,
      intensity: intensity,
      range: range,
    ),
    _ => SpotLight(
      name: name,
      color: color,
      intensity: intensity,
      range: range,
      angle: outer,
      penumbra: 1 - inner / outer,
    ),
  };
}
