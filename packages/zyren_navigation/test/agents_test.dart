import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_navigation/agents.dart';
import 'package:zyren_navigation/zyren_navigation.dart';

void main() {
  test(
    'registered path queries validate inputs and preserve explicit empty status',
    () async {
      final mesh = NavigationMesh(
        vertices: const [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)],
        triangles: const [
          [0, 1, 2],
        ],
      );
      final registry = AgentRegistry(), scope = AttachmentScope();
      var available = true;
      final provider = NavigationAgentProvider(
        mesh: mesh,
        instanceId: 'floor',
        sourceId: 'fixture.floor',
        isAvailable: () => available,
      )..register(registry, scope);
      Future<AgentResult> call(Map<String, Object?> args) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'find_path',
        arguments: args,
      );
      try {
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: 'find_path',
            arguments: {
              'start': [.1, 0, .1],
              'goal': [.2, 0, .1],
            },
          ),
          isEmpty,
        );
        expect(
          (await call({
            'start': [0, 0],
            'goal': [0, 0, 0],
          })).status,
          AgentStatus.invalid,
        );
        final empty = await call({
          'start': [.1, 0, .1],
          'goal': [2, 0, 2],
        });
        expect(empty.status, AgentStatus.empty);
        expect(empty.data['status'], 'goalOutside');
        expect(empty.data['points'], isEmpty);
        available = false;
        expect(
          (await call({
            'start': [0, 0, 0],
            'goal': [0, 0, 0],
          })).status,
          AgentStatus.stale,
        );
        scope.close();
        await scope.whenClosed;
        expect(registry.discover()['providers'], isEmpty);
      } finally {
        scope.close();
        registry.dispose();
      }
    },
  );
}
