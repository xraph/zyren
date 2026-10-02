import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_audio/agents.dart';

void main() {
  test(
    'agent controls real native playback with guards and detached targets',
    () async {
      final root = Scene(),
          listener = root.add(Group()),
          node = root.add(Group());
      final audio = SpatialAudio(
        root: root,
        listener: AudioListener(listener),
        offline: true,
      );
      addTearDown(audio.close);
      final emitter = audio.add(
        id: 'source',
        node: node,
        samples: Float32List.fromList(List.filled(4800, .1)),
        settings: EmitterSettings(loop: true),
      );
      final provider = AudioAgentProvider(
        audio: audio,
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'audio',
      );
      final registry = AgentRegistry(grantedScopes: {'audio.write'}),
          registration = registry.register(provider);
      addTearDown(registry.dispose);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      expect(provider.metadata(node)!.sourceId, 'source');
      final rev = provider.revision;
      Future<AgentResult> play() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'play',
        arguments: {'emitterId': 'source'},
        expectedRevision: rev,
        idempotencyKey: 'play',
      );
      final played = await play();
      expect(played.status, AgentStatus.ok);
      expect(await play(), same(played));
      expect(audio.renderOffline(1000).any((v) => v != 0), isTrue);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'configure',
          arguments: {'emitterId': 'source', 'volume': 2},
          expectedRevision: provider.revision,
          idempotencyKey: 'bad',
        )).status,
        AgentStatus.invalid,
      );
      final denied = AgentRegistry()..register(provider);
      addTearDown(denied.dispose);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'pause',
          arguments: {'emitterId': 'source'},
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'pause',
          arguments: {'emitterId': 'source'},
          expectedRevision: provider.revision,
          idempotencyKey: 'pause',
        )).status,
        AgentStatus.ok,
      );
      expect(emitter.isPlaying, isFalse);
      root.remove(node);
      expect(provider.metadata(node), isNull);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'play',
          arguments: {'emitterId': 'source'},
          expectedRevision: provider.revision,
          idempotencyKey: 'removed',
        )).status,
        AgentStatus.stale,
      );
      registration.dispose();
      expect(registry.discover()['providers'], isEmpty);
    },
  );
}
