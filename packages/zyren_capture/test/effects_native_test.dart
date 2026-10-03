import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_capture/effects_agents.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'agent rebuilds real native effects, undo and detach release resources',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(.213, .331, .447);
      final effects = ScreenEffectsPlugin(
        settings: ScreenEffectsSettings(smaa: null, dithering: false),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => backend.createView(),
        plugins: [effects],
      );
      final registry = AgentRegistry(grantedScopes: {'effects.write'});
      final provider = EffectsAgentProvider(
        scene: scene,
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'effects',
        effects: effects.controller,
      );
      registry.register(provider);
      var sequence = 0;
      Future<AgentResult> call(
        String tool, [
        Map<String, Object?> args = const {},
      ]) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        arguments: args,
        expectedRevision: provider.revision,
        idempotencyKey: 'command-${sequence++}',
      );
      try {
        final before = await engine.render(
          elapsed: Duration.zero,
          width: 64,
          height: 48,
        );
        final baseBytes = (await backend.resourceStats()).residentBytes;
        final changed = await call('chain', {'dithering': true, 'smaa': 'low'});
        expect(changed.status, AgentStatus.ok);
        expect(scene.effects.length, 4);
        final oldGeneration = effects.controller.generation;
        await engine.render(elapsed: Duration.zero, width: 64, height: 48);
        expect(effects.controller.generation, oldGeneration);
        expect(
          (await backend.resourceStats()).residentBytes,
          greaterThan(baseBytes),
        );
        expect((await call('undo')).status, AgentStatus.ok);
        expect(scene.effects, isEmpty);
        expect((await backend.resourceStats()).residentBytes, baseBytes);
        expect(
          (await call('configure', {'exposure': .2})).status,
          AgentStatus.ok,
        );
        final after = await engine.render(
          elapsed: Duration.zero,
          width: 64,
          height: 48,
        );
        expect(after.pixels, isNot(orderedEquals(before.pixels)));
        expect(
          (await call('chain', {
            'lens': true,
            'lensIntensity': .01,
            'lensThreshold': .1,
          })).status,
          AgentStatus.ok,
        );
        expect(scene.effects.length, 22);
        final old = effects.controller.settings;
        final denied = AgentRegistry()..register(provider);
        expect(
          (await denied.call(
            providerId: provider.id,
            instanceId: provider.instanceId,
            tool: 'chain',
            arguments: {'smaa': 'high'},
            expectedRevision: provider.revision,
            idempotencyKey: 'denied',
          )).status,
          AgentStatus.denied,
        );
        denied.dispose();
        expect(
          (await call('chain', {'lensIntensity': -1})).status,
          AgentStatus.invalid,
        );
        expect(effects.controller.settings, same(old));
        final undo = call('undo');
        scene.renderSettings = scene.renderSettings.copyWith(exposure: .37);
        expect((await undo).status, AgentStatus.stale);
        expect(scene.renderSettings.exposure, .37);
        scene.add(Group());
        expect((await call('undo')).status, AgentStatus.stale);
        await engine.dispose();
        expect(scene.effects, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        expect(
          (await call('chain', {'dithering': false})).status,
          AgentStatus.unavailable,
        );
      } finally {
        registry.dispose();
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
