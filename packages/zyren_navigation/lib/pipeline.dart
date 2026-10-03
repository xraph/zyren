/// Optional navigation bake from a completed, version-pinned pipeline job.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'zyren_navigation.dart';

BakedNavigationMesh bakePipelineNavigation(
  PipelineJob job, {
  required String transformRevision,
  Vec3 position = Vec3.zero,
  Quat rotation = Quat.identity,
  Vec3 scale = Vec3.one,
  NavigationBakeSettings? settings,
  bool Function()? cancelled,
}) {
  if (job.state != PipelineJobState.succeeded ||
      job.model == null ||
      transformRevision.trim().isEmpty) {
    throw StateError(
      'Navigation needs a completed model job and transform revision.',
    );
  }
  final model = job.model!.instantiate()
    ..position = position
    ..quaternion = rotation
    ..scale = scale;
  final geometry = <NavigationGeometry>[];
  for (final node in model.nodes.entries) {
    var primitive = 0;
    for (final mesh in node.value.children.whereType<Mesh>()) {
      geometry.add(
        NavigationGeometry.fromMesh(
          mesh,
          sourceId: '${job.sourceId}/node/${node.key}/primitive/${primitive++}',
          revision: '${job.bundleVersion}/$transformRevision',
        ),
      );
    }
  }
  return NavigationBaker(
    settings: settings,
  ).bake(geometry, cancelled: cancelled);
}
