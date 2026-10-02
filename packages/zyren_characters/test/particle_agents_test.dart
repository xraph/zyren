import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/agents.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  test('particle tool schemas declare read coverage and playback scopes', () {
    final tools = ParticleAgentProvider.toolDefinitions;
    for (final tool in tools) {
      AgentSchema.check(tool.inputSchema);
      AgentSchema.check(tool.outputSchema);
    }
    expect(tools.first.readOnly, isTrue);
    expect(tools.last.requiredScopes, {'particles.playback'});
  });
  test(
    'native particle provider reads cached state and applies host playback',
    () async {
      final plugin = ParticlePlugin(
        emitters: [
          ParticleEmitter(
            name: 'dust',
            settings: ParticleSettings(capacity: 8, rate: 1),
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: NativeBackend.create,
        plugins: [plugin],
      );
      final registry = AgentRegistry(grantedScopes: {'particles.playback'}),
          scope = AttachmentScope();
      var revision = 0;
      final provider = ParticleAgentProvider(
        controller: plugin.controller,
        instanceId: 'dust',
        readRevision: () => revision,
        isAvailable: () => !plugin.controller.isClosed,
        runCommand: (name, apply) async {
          await apply();
          revision++;
        },
      )..register(registry, scope);
      try {
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: 'inspect',
          ),
          isEmpty,
        );
        final result = await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'playback',
          arguments: {'action': 'pause', 'emitter': 'dust'},
          expectedRevision: 0,
          idempotencyKey: 'pause',
        );
        expect(result.status, AgentStatus.ok);
        expect(plugin.controller.playback('dust'), ParticlePlayback.paused);
        await plugin.controller.remove('dust');
        revision++;
        expect(
          (await registry.call(
            providerId: provider.id,
            instanceId: provider.instanceId,
            tool: 'playback',
            arguments: {'action': 'resume', 'emitter': 'dust'},
            expectedRevision: revision,
            idempotencyKey: 'removed',
          )).status,
          AgentStatus.stale,
        );
      } finally {
        scope.close();
        await scope.whenClosed;
        registry.dispose();
        await engine.dispose();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
