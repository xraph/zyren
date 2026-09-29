part of '../zyren_3d_tiles.dart';

/// A feature within one tile instance. IDs can repeat in other tiles.
final class TileFeature3D {
  final ModelFeature identity;
  final Map<String, Object?> properties;
  final _meshes = <ModelMesh>[];
  TileFeature3D._(this.identity, this.properties);
  int? get id => identity.id;
  String? get label => identity.label;
  int get setIndex => identity.setIndex;
}

final class TileFeatureStyle3D {
  final bool show;
  final Color3? color;
  final double? opacity;
  TileFeatureStyle3D({this.show = true, this.color, this.opacity}) {
    color?.toList();
    if (opacity != null &&
        (!opacity!.isFinite || opacity! < 0 || opacity! > 1)) {
      throw ArgumentError('Feature opacity must be between zero and one.');
    }
  }
}

/// Evaluated during explicit restyling and tile arrival, outside rendering.
final class TileStyle3D {
  final TileFeatureStyle3D Function(TileFeature3D feature) evaluate;
  final String? featureLabel;
  final int featureSet;
  TileStyle3D(this.evaluate, {this.featureLabel, this.featureSet = 0}) {
    RangeError.checkNotNegative(featureSet, 'featureSet');
  }
  bool _matches(TileFeature3D feature) => featureLabel == null
      ? feature.setIndex == featureSet
      : feature.label == featureLabel;
}

typedef _StyleEdit = (ModelMesh, MeshMaterial, bool);

/// A tile instance owns its style state while sharing immutable model resources.
final class TileModelInstance3D extends _TransformGroup {
  final _features = <TileFeature3D>[];
  final _original = <ModelMesh, (MeshMaterial, bool)>{};
  List<TileFeature3D> get features => List.unmodifiable(_features);
  TileModelInstance3D._(
    super.transform,
    Object3D model,
    List<ModelPropertyTable> tables,
    ModelPropertyTable? batch,
  ){
    final grouped = <(int, String?, int?, int?, bool), TileFeature3D>{};
    void visit(Object3D object) {
      if (object is ModelMesh) {
        _original[object] = (object.material, object.visible);
        if (batch != null &&
            batch.count > 0 &&
            !object.features.any((f) => f.legacyBatch)) {
          _invalid();
        }
        for (final identity in object.features) {
          final table = identity.legacyBatch
              ? batch
              : identity.propertyTable == null
              ? null
              : tables[identity.propertyTable!];
          if (identity.legacyBatch && batch == null) _invalid();
          final id = identity.id;
          if (id != null && table != null && (id < 0 || id >= table.count)) {
            _invalid();
          }
          final key = (
            identity.setIndex,
            identity.label,
            identity.propertyTable,
            id,
            identity.legacyBatch,
          );
          final feature = grouped.putIfAbsent(
            key,
            () => TileFeature3D._(
              identity,
              id == null || table == null ? const {} : table.properties(id),
            ),
          );
          feature._meshes.add(object);
        }
      }
      for (final child in object.children) {
        visit(child);
      }
    }

    visit(model);
    _features.addAll(grouped.values);
  }

  TileFeature3D? featureFor(
    PickResult pick, {
    int featureSet = 0,
    String? featureLabel,
  }) {
    for (final feature in _features) {
      if ((featureLabel == null
              ? feature.setIndex == featureSet
              : feature.label == featureLabel) &&
          feature._meshes.contains(pick.object)) {
        return feature;
      }
    }
    return null;
  }

  /// Passing null restores the instance's authored material and visibility.
  void setStyle(TileStyle3D? style) => _applyStyle(_prepareStyle(style));

  List<_StyleEdit> _prepareStyle(TileStyle3D? style) {
    final edits = {for (final e in _original.entries) e.key: e.value};
    if (style != null) {
      for (final feature in _features.where(style._matches)) {
        final value = style.evaluate(feature);
        for (final mesh in feature._meshes) {
          final (material, visible) = _original[mesh]!;
          final opacity = value.opacity ?? material.opacity;
          final alpha = opacity < 1
              ? MaterialAlphaMode.blend
              : material.alphaMode;
          final color = value.color;
          final changed = color == null && value.opacity == null
              ? material
              : switch (material) {
                  StandardMaterial m => m.copyWith(
                    color: color,
                    opacity: opacity,
                    alphaMode: alpha,
                  ),
                  UnlitMaterial m => m.copyWith(
                    color: color,
                    opacity: opacity,
                    alphaMode: alpha,
                  ),
                  PointsMaterial m => m.copyWith(
                    color: color,
                    opacity: opacity,
                    alphaMode: alpha,
                  ),
                  _ => throw StateError('Unsupported feature material.'),
                };
          edits[mesh] = (changed, visible && value.show);
        }
      }
    }
    return [for (final e in edits.entries) (e.key, e.value.$1, e.value.$2)];
  }
}

void _applyStyle(List<_StyleEdit> edits) {
  for (final (mesh, material, visible) in edits) {
    mesh.material = material;
    mesh.visible = visible;
  }
}
