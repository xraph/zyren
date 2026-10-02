import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

/// The export pipeline supplies both a pinned model and its source-ID sidecar.
/// Keep the asset scope alive until you release the model's scene resources.
Future<Group> importReviewModel({
  required AssetScope assets,
  required Scene scene,
  required SceneEngineeringPlugin review,
  required Uri source,
  required String modelVersion,
  required String sidecar,
}) async {
  final model = await assets
      .load(Gltf.uri(source, version: modelVersion))
      .result;
  final root = model.instantiate();
  final imported = EngineeringImport.fromSidecar(
    root: root,
    modelVersion: modelVersion,
    source: sidecar,
  );
  scene.add(root);
  try {
    review.rebindImport(imported);
    return root;
  } catch (_) {
    scene.remove(root);
    rethrow;
  }
}
