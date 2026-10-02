import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration/agent_provider.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';

/// Direct shared-registry example. Picking uses CPU triangles, with no GPU claim.
Future<void> main() async {
  final id = SceneObjectId(source: 'assembly', key: 'housing');
  final authority = LocalSceneAuthority(
    initial: SceneSnapshot(
      sceneId: 'scene',
      epoch: 'demo-1',
      objects: [SceneObjectState(id: id)],
    ),
    canRead: (principal, _) => principal == 'demo-user',
    canWrite: (principal, _, _) => principal == 'demo-user',
  );
  var sequence = 0;
  final client = SceneCollaborationClient(
    transport: authority.connect('demo-user'),
    sceneId: 'scene',
    epoch: 'demo-1',
    nextOperationId: () => 'demo-${++sequence}',
  );
  final scene = Scene();
  final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial(), name: 'Housing'));
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
  final binding = SceneCollaborationBinding(scene: scene, client: client);
  final registry = AgentRegistry(
    grantedScopes: {'collaboration.read', 'collaboration.write'},
  );
  try {
    await client.refresh();
    binding.rebind({id: mesh});
    final collaboration = CollaborationAgentProvider(
      client: client,
      binding: binding,
      instanceId: 'shared-scene',
      documentId: 'assembly-document',
    );
    final viewport = AgentViewportProvider(
      sceneId: 'scene',
      documentId: 'assembly-document',
      instanceId: 'main-view',
      scene: scene,
      camera: () => camera,
      viewport: () => const ViewportMetrics(320, 180, devicePixelRatio: 2),
      documentRevision: () => client.snapshot!.revision,
      metadata: collaboration.metadataFor,
    );
    registry.register(collaboration);
    registry.register(viewport);
    final providers = registry.discover()['providers'] as List;
    print('Discovered ${providers.length} shared providers.');
    final hit = await registry.call(
      providerId: viewport.id,
      instanceId: viewport.instanceId,
      tool: 'pick',
      arguments: {'x': 160, 'y': 90},
      expectedRevision: viewport.revision,
    );
    if (hit.status != AgentStatus.ok) {
      throw StateError('CPU triangle pick failed.');
    }
    final record = ((hit.data['hits'] as List).first as Map)['object'] as Map;
    final source = SceneObjectId.fromJson(
      jsonDecode((record['metadata'] as Map)['sourceId'] as String),
    );
    print(
      'Picked source=${source.key}, runtime=${record['runtimeId']}, pixel visibility=unknown.',
    );
    final action = await registry.call(
      providerId: collaboration.id,
      instanceId: collaboration.instanceId,
      tool: 'set_visibility',
      arguments: {'source': source.source, 'key': source.key, 'visible': false},
      expectedRevision: collaboration.revision,
      idempotencyKey: 'hide-picked-object',
    );
    if (action.status != AgentStatus.ok || mesh.visible) {
      throw StateError('Shared visibility action failed: ${action.status}.');
    }
    final after = await registry.call(
      providerId: viewport.id,
      instanceId: viewport.instanceId,
      tool: 'pick',
      arguments: {'x': 160, 'y': 90},
      expectedRevision: viewport.revision,
    );
    if (after.status != AgentStatus.empty) {
      throw StateError('Hidden object remained pickable.');
    }
    print(
      'Authorized action committed scene revision ${client.snapshot!.revision}; next pick is empty.',
    );
  } finally {
    registry.dispose();
    await binding.dispose();
    await client.close();
  }
}
