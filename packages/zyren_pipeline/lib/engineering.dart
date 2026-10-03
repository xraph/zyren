import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_engineering/cad_bundle.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'zyren_pipeline.dart';

/// A verified CAD model, source identity bindings and their CPU resource scope.
/// Add [instance] to your scene, then call engineering.rebindImport(imported).
final class PipelineEngineeringModel {
  final ModelInstance instance;
  final EngineeringImport imported;
  final String bundleVersion, modelVersion, modelSourceId;
  final AssetScope _scope;
  PipelineEngineeringModel._(
    this.instance,
    this.imported,
    this.bundleVersion,
    this.modelVersion,
    this.modelSourceId,
    this._scope,
  );
  static Future<PipelineEngineeringModel> load({
    required PipelineBundle bundle,
    required String modelSourceId,
    required String sidecarSourceId,
    AssetServices services = const AssetServices(),
    LoadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final cad = EngineeringCadBundle.decode(
      bundle.resource(modelSourceId).bytes,
      utf8.decode(bundle.resource(sidecarSourceId).bytes),
    );
    final scope = bundle.open(services: services);
    final task = scope.load(bundle.gltfRequest(sourceId: modelSourceId));
    final registration = cancellation?.onCancel(task.cancel);
    try {
      final model = await task.result;
      cancellation?.throwIfCancelled();
      final instance = model.instantiate();
      final imported = EngineeringImport.fromSidecar(
        root: instance,
        modelVersion: cad.version,
        source: cad.sidecar,
      );
      return PipelineEngineeringModel._(
        instance,
        imported,
        bundle.version,
        cad.version,
        modelSourceId,
        scope,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    } finally {
      registration?.dispose();
    }
  }

  Future<void> close() => _scope.close();
}
