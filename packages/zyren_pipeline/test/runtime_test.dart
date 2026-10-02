import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_pipeline/gltf_metadata.dart';

import '../example/triangle_source.dart';

Future<(PipelineRuntime, PipelineBundle)> fixture({
  int maxJobs = 4,
  int maxActive = 2,
}) async {
  final source = TriangleSource();
  final bundle = await PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
  final runtime = PipelineRuntime(
    cache: PipelineCache()..put(bundle),
    maxJobs: maxJobs,
    maxActiveJobs: maxActive,
  );
  return (runtime, bundle);
}

void main() {
  test(
    'load retains template until ordinary release and records validation',
    () async {
      final (runtime, bundle) = await fixture();
      addTearDown(runtime.close);
      final validation = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.validate,
      );
      await validation.done;
      expect(validation.state, PipelineJobState.succeeded);
      expect(validation.model, isNull);
      final load = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      await load.done;
      final model = load.model!;
      expect(model.isReleased, isFalse);
      expect(load.progress, isNotNull);
      expect(await runtime.release(load.id), isTrue);
      expect(model.isReleased, isTrue);
      expect(load.state, PipelineJobState.released);
      expect(await runtime.release(load.id), isFalse);
    },
  );

  test(
    'active and retained job budgets fail before admitting more work',
    () async {
      final (runtime, bundle) = await fixture(maxJobs: 1, maxActive: 1);
      addTearDown(runtime.close);
      final load = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      expect(
        () => runtime.start(
          bundleVersion: bundle.version,
          kind: PipelineJobKind.load,
        ),
        throwsStateError,
      );
      await load.done;
      expect(
        () => runtime.start(
          bundleVersion: bundle.version,
          kind: PipelineJobKind.load,
        ),
        throwsStateError,
      );
      await runtime.release(load.id);
      final next = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.validate,
      );
      expect(runtime.job(load.id), isNull);
      await next.done;
      expect(runtime.jobs.length, 1);
    },
  );

  test('cancel and close release work and reject stale bundle jobs', () async {
    final (runtime, bundle) = await fixture();
    final cancelled = runtime.start(
      bundleVersion: bundle.version,
      kind: PipelineJobKind.load,
    );
    expect(runtime.cancel(cancelled.id), isTrue);
    await cancelled.done;
    expect(cancelled.state, PipelineJobState.cancelled);
    expect(cancelled.model, isNull);
    final loaded = runtime.start(
      bundleVersion: bundle.version,
      kind: PipelineJobKind.load,
    );
    await loaded.done;
    final model = loaded.model!;
    runtime.invalidateSource('model');
    expect(
      () => runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      ),
      throwsStateError,
    );
    await runtime.close();
    expect(model.isReleased, isTrue);
    expect(runtime.jobs, isEmpty);
    expect(() => runtime.cancel(cancelled.id), throwsStateError);
  });

  test('missing dependencies become explicit failed job codes', () async {
    final source = TriangleSource();
    final incomplete = await PipelineBuilder(
      resolver: source,
    ).build(entrySourceId: 'model', sources: [source.sources.first]);
    final runtime = PipelineRuntime(cache: PipelineCache()..put(incomplete));
    addTearDown(runtime.close);
    final job = runtime.start(
      bundleVersion: incomplete.version,
      kind: PipelineJobKind.validate,
    );
    await job.done;
    expect(job.state, PipelineJobState.failed);
    expect(job.errorCode, AssetLoadError.sourceUnavailable.name);
  });

  test(
    'optional glTF enrichment preserves host bindings without pixel claims',
    () async {
      final (runtime, bundle) = await fixture();
      addTearDown(runtime.close);
      final job = runtime.start(
        bundleVersion: bundle.version,
        kind: PipelineJobKind.load,
      );
      await job.done;
      final instance = job.model!.instantiate();
      final metadata = PipelineGltfMetadata(
        bundleVersion: bundle.version,
        sourceId: 'model',
        sourceRevision: 'drawing-r1',
        instance: instance,
        sourceIds: {0: 'part:triangle'},
      );
      final node = instance.nodes[0]!;
      expect(metadata.inspect(node)!['stableObjectId'], 'part:triangle');
      expect(metadata.inspect(node)!['runtimeObjectId'], node.id);
      expect(metadata.inspect(node)!['pixelVisibility'], 'unknown');
      expect(
        metadata.inspect(node.children.single)!['bindingRelationship'],
        'ancestor',
      );
      instance.remove(node);
      expect(metadata.inspect(node), isNull);
      expect(metadata.inspect(Group()), isNull);
      expect(
        () => PipelineGltfMetadata(
          bundleVersion: bundle.version,
          sourceId: 'model',
          sourceRevision: 'drawing-r1',
          instance: instance,
          sourceIds: {99: 'missing'},
        ),
        throwsArgumentError,
      );
    },
  );
}
