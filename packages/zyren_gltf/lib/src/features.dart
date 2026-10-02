import 'package:zyren/zyren.dart';

/// Identity within one model feature set. IDs are local to the model's table.
final class ModelFeature {
  final int setIndex;
  final int? id, propertyTable;
  final String? label;
  final bool legacyBatch;
  const ModelFeature({
    required this.setIndex,
    required this.id,
    this.propertyTable,
    this.label,
    this.legacyBatch = false,
  });
}

abstract interface class ModelFeatureMesh implements Mesh {
  List<ModelFeature> get features;
}

/// An ordinary native mesh whose geometry belongs to these feature identities.
final class ModelMesh extends Mesh implements ModelFeatureMesh {
  @override
  final List<ModelFeature> features;
  ModelMesh(
    super.geometry,
    super.material, {
    super.name,
    required List<ModelFeature> features,
  }) : features = List.unmodifiable(features);
}

/// A skinned native mesh carrying the same feature identities as rigid meshes.
final class ModelSkinnedMesh extends SkinnedMesh implements ModelFeatureMesh {
  @override
  final List<ModelFeature> features;
  ModelSkinnedMesh(
    super.geometry,
    super.material, {
    required super.skin,
    super.name,
    required List<ModelFeature> features,
  }) : features = List.unmodifiable(features);
}
