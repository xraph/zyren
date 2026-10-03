import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_navigation/pipeline.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../../zyren_pipeline/example/triangle_source.dart';

void main() {
  test(
    'completed pipeline model bakes with bundle, node and transform identities',
    () async {
      final source = TriangleSource();
      final bundle = await PipelineBuilder(
        resolver: source,
      ).build(entrySourceId: 'model', sources: source.sources);
      final runtime = PipelineRuntime(cache: PipelineCache()..put(bundle));
      try {
        final job = runtime.start(
          bundleVersion: bundle.version,
          kind: PipelineJobKind.load,
        );
        expect(
          () => bakePipelineNavigation(job, transformRevision: '1'),
          throwsStateError,
        );
        await job.done;
        expect(job.state, PipelineJobState.succeeded);
        final mesh = bakePipelineNavigation(
          job,
          transformRevision: 'pose-7',
          scale: const Vec3(6, 6, 6),
          rotation: Quat.axisAngle(const Vec3(1, 0, 0), -math.pi / 2),
          settings: NavigationBakeSettings(cellSize: .2, radius: .1),
        );
        expect(mesh.cells, isNotEmpty);
        expect(mesh.sources.keys.single, 'model/node/0/primitive/0');
        expect(mesh.sources.values.single, '${bundle.version}/pose-7');
        await runtime.release(job.id);
        expect(
          () => bakePipelineNavigation(job, transformRevision: '2'),
          throwsStateError,
        );
        expect(mesh.cells, isNotEmpty);
      } finally {
        await runtime.close();
      }
    },
  );
}
