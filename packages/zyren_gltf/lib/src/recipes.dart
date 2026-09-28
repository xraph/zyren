import 'dart:typed_data';
import 'package:zyren/zyren.dart';

final class PreparedModel {
  final List<NodeRecipe> nodes;
  final List<SceneRecipe> scenes;
  final int? defaultScene;
  final List<List<PrimitiveRecipe>> meshes;
  final Map<int, ImageRecipe> images;
  final List<SceneIssue> issues;
  final int decodedBytes;
  const PreparedModel(
    this.nodes,
    this.scenes,
    this.defaultScene,
    this.meshes,
    this.images,
    this.issues,
    this.decodedBytes,
  );
}

final class NodeRecipe {
  final String? name;
  final Vec3 position, scale;
  final Quat rotation;
  final int? mesh;
  final List<int> children;
  const NodeRecipe(
    this.name,
    this.position,
    this.rotation,
    this.scale,
    this.mesh,
    this.children,
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
  const PrimitiveRecipe(this.geometry, this.material, this.name);
}

final class MaterialRecipe {
  final Color3 color;
  final double opacity, cutoff;
  final MaterialAlphaMode alphaMode;
  final MaterialSide side;
  final ImageBindingRecipe? colorMap;
  const MaterialRecipe(
    this.color,
    this.opacity,
    this.cutoff,
    this.alphaMode,
    this.side,
    this.colorMap,
  );
}

final class ImageBindingRecipe {
  final int source, uvSet;
  final bool mipmaps;
  final SamplerDescriptor sampler;
  const ImageBindingRecipe(this.source, this.uvSet, this.mipmaps, this.sampler);
}

final class ImageRecipe {
  final String? uri, mediaType;
  final Uint8List? bytes;
  const ImageRecipe(this.uri, this.mediaType, this.bytes);
}
