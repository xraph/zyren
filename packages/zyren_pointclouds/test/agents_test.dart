import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/agents.dart';

void main() {
  test(
    'shared discovery, logical screen queries, classification and source identity',
    () async {
      final scene = Scene(), registry = AgentRegistry();
      final camera = OrthographicCamera();
      final cloud = ScenePointCloud(
        data: PointCloudData(
          sourceUri: Uri.parse('memory:survey'),
          sourceVersion: 'v3',
          points: [const Vec3(.5, 0, 0)],
          classifications: [6],
        ),
      );
      scene.add(cloud.object);
      final view = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'document',
        instanceId: 'right-view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(100, 100, devicePixelRatio: 2),
        units: 'm',
      );
      final provider = PointCloudAgentProvider(
        cloud: cloud,
        view: view,
        instanceId: 'survey',
      );
      provider.register(registry);
      expect(
        (registry.discover()['providers'] as List).single['providerId'],
        'zyren.pointclouds',
      );
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      final before = scene.revision;
      final hit = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'pick',
        expectedRevision: before,
        arguments: {'x': 75, 'y': 50, 'radius': .01},
      );
      expect(hit.status, AgentStatus.ok);
      final sample = (hit.data['hits'] as List).single as Map;
      expect(sample['recordIndex'], 0);
      expect(sample['classification'], 6);
      expect(sample['sourceVersion'], 'v3');
      expect(sample['worldPoint'], [.5, 0, 0]);
      expect(sample['renderedPixelVisibility'], 'unknown');
      expect((hit.data['context'] as Map)['viewportId'], 'right-view');
      expect((hit.data['context'] as Map)['frameCorrelation'], 'unknown');
      expect(scene.revision, before);
      cloud.object.position = const Vec3(.1, 0, 0);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
          expectedRevision: before,
        )).status,
        AgentStatus.stale,
      );
      scene.remove(cloud.object);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
        )).status,
        AgentStatus.stale,
      );
      cloud.close();
      expect(registry.discover()['providers'], isEmpty);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
        )).status,
        AgentStatus.unavailable,
      );
      registry.dispose();
    },
  );

  test(
    'frame and camera mismatch, invalid input and unknown classification remain explicit',
    () async {
      final scene = Scene(), registry = AgentRegistry();
      final camera = OrthographicCamera();
      final cloud = ScenePointCloud(
        data: PointCloudData(
          sourceUri: Uri.parse('memory:survey'),
          sourceVersion: '1',
          points: [Vec3.zero],
        ),
      );
      expect(cloud.data.classificationAt(0), isNull);
      scene.add(cloud.object);
      final view = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(100, 100),
        presentedFrame: () =>
            const AgentPresentedFrame(id: 'old', sceneRevision: 0),
      );
      final provider = PointCloudAgentProvider(
        cloud: cloud,
        view: view,
        instanceId: 'cloud',
      );
      provider.register(registry);
      Future<AgentResult> pick(Map<String, Object?> extra) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'pick',
        arguments: {'x': 50, 'y': 50, 'radius': .1, ...extra},
      );
      expect(
        (await pick({'expectedFrameId': 'old'})).status,
        AgentStatus.stale,
      );
      expect(
        (await pick({'expectedCameraRevision': 999})).status,
        AgentStatus.stale,
      );
      expect((await pick({'radius': 0})).status, AgentStatus.invalid);
      expect((await pick({'x': 101})).status, AgentStatus.invalid);
      cloud.close();
      registry.dispose();
    },
  );
}
