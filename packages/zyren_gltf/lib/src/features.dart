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

/// An ordinary native mesh whose geometry belongs to these feature identities.
final class ModelMesh extends Mesh {
  final List<ModelFeature> features;
  ModelMesh(
    super.geometry,
    super.material, {
    super.name,
    required List<ModelFeature> features,
  }) : features = List.unmodifiable(features);
}
