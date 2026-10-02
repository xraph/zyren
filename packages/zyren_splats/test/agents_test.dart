import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_splats/zyren_splats.dart';
import 'package:zyren_splats/agents.dart';

void main() {
  test(
    'shared provider reports bounded appearance estimates and unknown pixel coverage',
    () async {
      final scene = Scene(),
          registry = AgentRegistry(),
          lifetime = AttachmentScope();
      final object = scene.add(Group());
      Camera camera = OrthographicCamera();
      final cloud = GaussianCloudData(
        sourceUri: Uri.parse('memory:splats'),
        sourceVersion: 'v1',
        splats: [
          for (final z in [1.0, -1.0])
            GaussianSplat(
              mean: Vec3(0, 0, z),
              covariance: GaussianCovariance(xx: .04, yy: .01, zz: .01),
              color: const Color3(1, 0, 0),
              opacity: .8,
            ),
        ],
      );
      final view = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'left-view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(100, 100, devicePixelRatio: 2),
      );
      final provider = GaussianAgentProvider(
        data: cloud,
        object: object,
        view: view,
        instanceId: 'cloud',
      );
      provider.register(registry, onClose: lifetime.onClose);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      Future<AgentResult> estimate({Map<String, Object?> extra = const {}}) =>
          registry.call(
            providerId: provider.id,
            instanceId: provider.instanceId,
            tool: 'estimate',
            arguments: {'x': 50, 'y': 50, 'limit': 1, ...extra},
          );
      final before = scene.revision, result = await estimate();
      expect(result.status, AgentStatus.ok);
      final hit = (result.data['hits'] as List).single as Map;
      expect(hit['recordIndex'], 0);
      expect(hit['estimatedOpacity'], closeTo(.8, 1e-12));
      expect(hit['measurementSurface'], false);
      expect(hit['renderedPixelVisibility'], 'unknown');
      expect(result.data['truncated'], true);
      expect((result.data['projectionSize'] as Map)['width'], 200);
      expect(scene.revision, before);
      expect(
        (await estimate(extra: {'limit': 33})).status,
        AgentStatus.invalid,
      );
      expect(
        (await estimate(extra: {'expectedFrameId': 'missing'})).status,
        AgentStatus.unavailable,
      );
      camera = PerspectiveCamera();
      expect((await estimate()).status, AgentStatus.unsupported);
      scene.remove(object);
      expect((await estimate()).status, AgentStatus.stale);
      lifetime.close();
      await lifetime.whenClosed;
      expect(registry.discover()['providers'], isEmpty);
      registry.dispose();
    },
  );
}
