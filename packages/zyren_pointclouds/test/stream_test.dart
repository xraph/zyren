import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/streaming.dart';

final bounds = Bounds3(const Vec3(-1, -1, -1), const Vec3(1, 1, 1));
SpatialChunk node(
  String id, {
  List<SpatialChunk> children = const [],
  int bytes = 32,
  int gpu = 16,
}) => SpatialChunk(
  id: id,
  uri: Uri.parse('memory:$id'),
  version: '1',
  bounds: bounds,
  geometricError: children.isEmpty ? 0 : 2,
  decodedBytes: bytes,
  gpuBytes: gpu,
  children: children,
);
final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
final size = PhysicalSize(100, 100);
Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  test(
    'resident ancestor remains until all selected replacements are ready',
    () async {
      final jobs = <String, Completer<SpatialPayload<String>>>{};
      final stream = SpatialStreamer(
        root: node('root', children: [node('a'), node('b')]),
        loader: (n, c) {
          final job = Completer<SpatialPayload<String>>();
          jobs[n.id] = job;
          return job.future;
        },
      );
      stream.update(camera, size);
      expect(stream.stats.reservedBytes, 96);
      jobs['root']!.complete(
        SpatialPayload('coarse', decodedBytes: 32, gpuBytes: 16),
      );
      await tick();
      expect(stream.visible, {'root': 'coarse'});
      jobs['a']!.complete(
        SpatialPayload('left', decodedBytes: 32, gpuBytes: 16),
      );
      await tick();
      expect(stream.visible.keys, ['root']);
      jobs['b']!.complete(
        SpatialPayload('right', decodedBytes: 32, gpuBytes: 16),
      );
      await stream.settle();
      expect(stream.visible, {'a': 'left', 'b': 'right'});
      expect(stream.stats.gpuPayloadBytes, 32);
      expect(stream.stats.toJson()['physicalGpuResidentBytes'], isNull);
      await stream.close();
    },
  );
  test(
    'obsolete requests drain, retain reservations and never republish stale results',
    () async {
      final jobs = <Completer<SpatialPayload<String>>>[],
          tokens = <LoadCancellation>[];
      var disposed = 0;
      final stream = SpatialStreamer(
        root: node('root'),
        loader: (n, c) {
          tokens.add(c);
          final job = Completer<SpatialPayload<String>>();
          jobs.add(job);
          return job.future;
        },
      );
      stream.update(camera, size);
      final away = PerspectiveCamera(
        position: const Vec3(0, 0, 5),
        target: const Vec3(0, 0, 10),
      );
      stream.update(away, size);
      expect(tokens.single.isCancelled, isTrue);
      expect(stream.stats.reservedBytes, 32);
      stream.update(camera, size);
      jobs.first.complete(
        SpatialPayload(
          'stale',
          decodedBytes: 32,
          gpuBytes: 16,
          onDispose: () => disposed++,
        ),
      );
      await tick();
      expect(disposed, 1);
      expect(stream.visible, isEmpty);
      expect(jobs.length, 2);
      jobs.last.complete(
        SpatialPayload(
          'current',
          decodedBytes: 32,
          gpuBytes: 16,
          onDispose: () => disposed++,
        ),
      );
      await stream.settle();
      expect(stream.visible.values, ['current']);
      await stream.close();
      expect(disposed, 2);
      expect(stream.stats.reservedBytes, 0);
    },
  );
  test(
    'failure needs explicit retry and over-reservation payloads are disposed',
    () async {
      var attempt = 0, disposed = 0;
      final stream = SpatialStreamer(
        root: node('root'),
        loader: (n, c) async {
          attempt++;
          return SpatialPayload(
            'data',
            decodedBytes: attempt == 1 ? 33 : 32,
            gpuBytes: 16,
            onDispose: () => disposed++,
          );
        },
      );
      stream.update(camera, size);
      await stream.settle();
      expect(stream.failures.keys, ['root']);
      expect(disposed, 1);
      stream.update(camera, size);
      expect(attempt, 1);
      stream.retryFailed();
      await stream.settle();
      expect(stream.visible.values, ['data']);
      expect(stream.failures, isEmpty);
      await stream.close();
      expect(disposed, 2);
    },
  );
  test(
    'GPU selection and CPU reservation budgets retain a coarse view',
    () async {
      final stream = SpatialStreamer(
        root: node('root', children: [node('a'), node('b')]),
        budget: const SpatialStreamBudget(
          maxGpuBytes: 16,
          maxDecodedBytes: 32,
          maxCachedBytes: 0,
          maxRequests: 1,
        ),
        loader: (n, c) async =>
            SpatialPayload(n.id, decodedBytes: 32, gpuBytes: 16),
      );
      stream.update(camera, size);
      await stream.settle();
      expect(stream.visible.keys, ['root']);
      expect(stream.stats.budgetLimited, isTrue);
      expect(
        stream.stats.decodedBytes + stream.stats.reservedBytes,
        lessThanOrEqualTo(32),
      );
      stream.update(
        PerspectiveCamera(
          position: const Vec3(0, 0, 5),
          target: const Vec3(0, 0, 10),
        ),
        size,
      );
      expect(stream.stats.decodedBytes, 0);
      expect(stream.visible, isEmpty);
      await stream.close();
    },
  );
  test(
    'octree selects original source records and point filter controls scene queries',
    () async {
      final data = PointCloudData(
        sourceUri: Uri.parse('memory:survey'),
        sourceVersion: 'v2',
        points: [const Vec3(-.5, 0, 0), const Vec3(.5, 0, 0)],
        recordIndices: [80, 99],
        classifications: [2, 7],
      );
      final tree = PointCloudOctree.fromData(data, samplesPerChunk: 1);
      final stream = SpatialStreamer(root: tree.root, loader: tree.load);
      final plugin = PointCloudStreamPlugin(stream: stream);
      plugin.update(camera, size);
      await stream.settle();
      plugin.update(camera, size);
      expect(plugin.visibleClouds.length, 2);
      expect(
        plugin
            .pick(Ray(const Vec3(.5, 0, 5), const Vec3(0, 0, -1)), radius: .01)
            ?.identity
            .$3,
        99,
      );
      plugin.filter = PointCloudFilter(classifications: {2});
      plugin.update(camera, size);
      expect(plugin.visibleClouds.length, 1);
      expect(
        plugin.pick(
          Ray(const Vec3(.5, 0, 5), const Vec3(0, 0, -1)),
          radius: .01,
        ),
        isNull,
      );
      expect(
        plugin
            .pick(Ray(const Vec3(-.5, 0, 5), const Vec3(0, 0, -1)), radius: .01)
            ?.identity
            .$3,
        80,
      );
      for (final cloud in plugin.visibleClouds.values) {
        cloud.close();
      }
      await stream.close();
    },
  );
}
