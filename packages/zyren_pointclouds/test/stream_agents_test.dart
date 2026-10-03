import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/streaming.dart';
import 'package:zyren_pointclouds/stream_agents.dart';

void main() {
  test(
    'stream commands are scoped, revisioned, retry-safe and undo through the scene filter',
    () async {
      final data = PointCloudData(
        sourceUri: Uri.parse('memory:agent'),
        sourceVersion: '1',
        points: [Vec3.zero, const Vec3(.5, 0, 0)],
        classifications: [2, 7],
      );
      final tree = PointCloudOctree.fromData(data, samplesPerChunk: 1);
      final plugin = PointCloudStreamPlugin(
        stream: SpatialStreamer(root: tree.root, loader: tree.load),
      );
      final scene = Scene()..add(plugin.object), camera = OrthographicCamera();
      final view = AgentViewportProvider(
        sceneId: 's',
        documentId: 'd',
        instanceId: 'v',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(100, 100),
      );
      final provider = PointCloudStreamAgentProvider(
        plugin: plugin,
        view: view,
        instanceId: 'p',
      );
      final denied = AgentRegistry();
      denied.register(provider);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: 'p',
          tool: 'filter',
          arguments: {
            'classifications': [2],
          },
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      denied.dispose();
      final registry = AgentRegistry(grantedScopes: {'pointclouds.filter'});
      registry.register(provider);
      plugin.update(camera, PhysicalSize(100, 100));
      await plugin.stream.settle();
      plugin.update(camera, PhysicalSize(100, 100));
      final revision = provider.revision;
      Future<AgentResult> filter() => registry.call(
        providerId: provider.id,
        instanceId: 'p',
        tool: 'filter',
        arguments: {
          'classifications': [2],
        },
        expectedRevision: revision,
        idempotencyKey: 'filter-1',
      );
      expect((await filter()).status, AgentStatus.ok);
      final first = plugin.filterRevision;
      expect((await filter()).status, AgentStatus.ok);
      expect(plugin.filterRevision, first);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: 'p',
          tool: 'undoFilter',
          expectedRevision: revision,
          idempotencyKey: 'stale',
        )).status,
        AgentStatus.stale,
      );
      plugin.update(camera, PhysicalSize(100, 100));
      expect(
        plugin.visibleClouds.values.expand(
          (c) => List.generate(c.data.count, c.data.classificationAt),
        ),
        everyElement(2),
      );
      final undo = await registry.call(
        providerId: provider.id,
        instanceId: 'p',
        tool: 'undoFilter',
        expectedRevision: provider.revision,
        idempotencyKey: 'undo-1',
      );
      expect(undo.status, AgentStatus.ok);
      expect(plugin.filter.classifications, isNull);
      plugin.update(camera, PhysicalSize(100, 100));
      final pick = await registry.call(
        providerId: provider.id,
        instanceId: 'p',
        tool: 'pick',
        arguments: {'x': 75, 'y': 50, 'radius': .01},
      );
      expect(pick.status, AgentStatus.ok);
      expect((pick.data['hits'] as List).single['recordIndex'], 1);
      registry.dispose();
      for (final cloud in plugin.visibleClouds.values) {
        cloud.close();
      }
      await plugin.stream.close();
    },
  );
}
