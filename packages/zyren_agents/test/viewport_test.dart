import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';

void main() {
  late Scene scene;
  late Mesh box;
  late Camera camera;
  late ViewportMetrics metrics;
  late AgentRegistry registry;
  late AgentViewportProvider provider;
  AgentPresentedFrame? frame;
  setUp(() {
    scene = Scene();
    box = scene.add(Mesh(BoxGeometry(), UnlitMaterial(), name: 'Part'));
    camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
    metrics = const ViewportMetrics(200, 100, devicePixelRatio: 3);
    frame = null;
    registry = AgentRegistry();
    provider = AgentViewportProvider(
      sceneId: 'scene',
      documentId: 'doc',
      instanceId: 'left',
      scene: scene,
      camera: () => camera,
      viewport: () => metrics,
      presentedFrame: () => frame,
      metadata: (object) => AgentObjectMetadata(
        sourceId: 'part-123',
        semanticType: 'test-part',
        properties: {'test.label': object.name},
      ),
    );
    registry.register(provider);
  });
  tearDown(() => registry.dispose());
  Future<AgentResult> call(
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) => registry.call(
    providerId: provider.id,
    instanceId: provider.instanceId,
    tool: tool,
    arguments: arguments,
  );
  test(
    'logical center pick returns geometry, provenance and honest coverage',
    () async {
      final result = await call('pick', {'x': 100, 'y': 50});
      expect(result.status, AgentStatus.ok);
      final hit = (result.data['hits'] as List).single as Map;
      expect((hit['object'] as Map)['runtimeId'], box.id);
      expect(
        ((hit['object'] as Map)['metadata'] as Map)['sourceId'],
        'part-123',
      );
      expect(hit['distance'], closeTo(4.5, 1e-6));
      expect(hit['worldPoint'], [0.0, 0.0, .5]);
      expect(hit['renderedPixelVisibility'], 'unknown');
      expect(result.data['frameCorrelation'], 'unknown');
      expect(result.data['devicePixelRatio'], 3);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'context',
        ),
        isEmpty,
      );
    },
  );
  test(
    'old frame is explicit and expected frame cannot join current geometry',
    () async {
      expect(
        (await call('pick', {
          'x': 100,
          'y': 50,
          'expectedFrameId': '1',
        })).status,
        AgentStatus.unavailable,
      );
      frame = AgentPresentedFrame(
        id: '1',
        sceneRevision: scene.revision,
        cameraRevision: camera.revision,
        cameraRuntimeId: camera.id,
        logicalWidth: metrics.width,
        logicalHeight: metrics.height,
        devicePixelRatio: metrics.devicePixelRatio,
      );
      expect(
        (await call('pick', {
          'x': 100,
          'y': 50,
          'expectedFrameId': '1',
        })).status,
        AgentStatus.ok,
      );
      box.position = const Vec3(1, 0, 0);
      expect(
        (await call('context')).data['frameCorrelation'],
        'differs-from-current-state',
      );
      expect(
        (await call('pick', {
          'x': 100,
          'y': 50,
          'expectedFrameId': '1',
        })).status,
        AgentStatus.stale,
      );
    },
  );
  test(
    'orthographic resize, camera changes, clipping and removed identities',
    () async {
      camera = OrthographicCamera(position: const Vec3(0, 0, 5));
      metrics = const ViewportMetrics(400, 200, devicePixelRatio: 2);
      expect((await call('pick', {'x': 200, 'y': 100})).status, AgentStatus.ok);
      expect(
        (await call('pick', {
          'x': 100,
          'y': 50,
          'expectedCameraRevision': 999,
        })).status,
        AgentStatus.stale,
      );
      camera = PerspectiveCamera(position: const Vec3(0, 0, 5), far: 1);
      expect(
        (await call('pick', {'x': 200, 'y': 100})).status,
        AgentStatus.empty,
      );
      scene.remove(box);
      expect(
        (await call('inspect_object', {'runtimeId': box.id})).status,
        AgentStatus.stale,
      );
    },
  );
  test(
    'viewports never silently select another camera and out of bounds is invalid',
    () async {
      registry.register(
        AgentViewportProvider(
          sceneId: 'scene',
          documentId: 'doc',
          instanceId: 'right',
          scene: scene,
          camera: () =>
              PerspectiveCamera(position: const Vec3(0, 0, 5), far: 1),
          viewport: () => metrics,
        ),
      );
      expect((registry.discover()['providers'] as List), hasLength(2));
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: 'right',
          tool: 'pick',
          arguments: {'x': 100, 'y': 50},
        )).status,
        AgentStatus.empty,
      );
      expect((await call('pick', {'x': 100, 'y': 50})).status, AgentStatus.ok);
      expect(
        (await call('pick', {'x': 201, 'y': 50})).status,
        AgentStatus.invalid,
      );
    },
  );
  test('scene and enrichment budgets are explicit failures', () async {
    registry.register(
      AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'tiny',
        scene: scene,
        camera: () => camera,
        viewport: () => metrics,
        maxNodes: 1,
      ),
    );
    expect(
      (await registry.call(
        providerId: provider.id,
        instanceId: 'tiny',
        tool: 'pick',
        arguments: {'x': 100, 'y': 50},
      )).status,
      AgentStatus.unavailable,
    );
    expect(
      () => AgentObjectMetadata(properties: {'large': 'x' * 10000}),
      throwsArgumentError,
    );
  });
}
