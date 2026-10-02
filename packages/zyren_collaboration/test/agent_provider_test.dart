import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/agent_provider.dart';
import 'package:zyren_collaboration/engineering_agent_provider.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/http_session_store.dart';
import 'package:zyren_engineering/review_server.dart';
import '../../zyren/test/support/fakes.dart';

final target = SceneObjectId(source: 'asset', key: 'housing');
SceneSnapshot initial() => SceneSnapshot(
  sceneId: 'scene',
  epoch: 'epoch',
  objects: [SceneObjectState(id: target)],
);
const scopes = {
  'collaboration.read',
  'collaboration.write',
  'engineering.read',
  'engineering.write',
  'engineering.view',
};

final class CollaborationHarness {
  final AgentRegistry registry;
  late final LocalSceneAuthority authority;
  late final SceneCollaborationClient client;
  late final SceneCollaborationPlugin collaboration;
  late final SceneCollaborationAgentPlugin agent;
  late final SceneEngine engine;
  final scene = Scene();
  late final Object3D object = scene.add(Group(name: 'Housing'));
  var readable = true, writable = true, sequence = 0;
  Completer<void>? permissionGate, permissionEntered;
  CollaborationHarness({Set<String> grants = scopes})
    : registry = AgentRegistry(grantedScopes: grants);
  CollaborationAgentProvider get provider => agent.provider!;
  Future<void> start() async {
    authority = LocalSceneAuthority(
      initial: initial(),
      canRead: (_, _) => readable,
      canWrite: (_, _, _) async {
        permissionEntered?.complete();
        await permissionGate?.future;
        return writable;
      },
    );
    client = SceneCollaborationClient(
      transport: authority.connect('host-user'),
      sceneId: 'scene',
      epoch: 'epoch',
      nextOperationId: () => 'edit-${++sequence}',
    );
    await client.refresh();
    collaboration = SceneCollaborationPlugin(client);
    agent = SceneCollaborationAgentPlugin(
      collaboration: collaboration,
      registry: registry,
      instanceId: 'viewport-main',
      documentId: 'saved-scene',
    );
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [collaboration, agent],
    );
    collaboration.binding.rebind({target: object});
  }

  Future<AgentResult> call(
    String tool, {
    Map<String, Object?> arguments = const {},
    bool write = false,
    int? expected,
    String? key,
    AgentCancellation? cancellation,
  }) => registry.call(
    providerId: provider.id,
    instanceId: provider.instanceId,
    tool: tool,
    arguments: arguments,
    expectedRevision: expected ?? provider.revision,
    idempotencyKey: write ? key ?? 'call-${sequence++}' : null,
    cancellation: cancellation,
  );
  Future<void> close() async {
    await engine.dispose();
    registry.dispose();
    await client.close();
  }
}

final class ReviewStore implements EngineeringSessionStore {
  EngineeringRevision value;
  int writes = 0;
  Completer<void>? gate;
  ReviewStore(EngineeringDocument document)
    : value = EngineeringRevision(version: '"v0"', document: document);
  @override
  Future<EngineeringRevision> read() async {
    await gate?.future;
    return value;
  }

  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) async {
    if (value.version != expectedVersion) {
      throw const EngineeringVersionConflict();
    }
    return value = EngineeringRevision(
      version: '"v${++writes}"',
      document: document,
    );
  }
}

void main() {
  test(
    'shared registry discovers schemas and reads without scene mutation',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      final descriptions = h.registry.discover()['providers'] as List;
      expect(descriptions.single['providerId'], 'zyren.collaboration');
      final tools = descriptions.single['tools'] as List;
      expect(
        tools.map((tool) => tool['name']),
        containsAll(['state', 'history', 'presence', 'set_transform']),
      );
      final before = h.scene.revision;
      expect(
        await AgentConformance.checkRead(
          registry: h.registry,
          provider: h.provider,
          tool: 'state',
        ),
        isEmpty,
      );
      final objects = await h.call('objects');
      expect(objects.status, AgentStatus.ok);
      expect(
        (objects.data['objects'] as List).single['runtimeId'],
        h.object.id,
      );
      expect(h.scene.revision, before);
      final metadata = h.provider.metadataFor(h.object)!;
      expect(metadata.sourceId, target.toString());
      expect(metadata.provenance['documentId'], 'saved-scene');
      expect((await h.call('presence')).status, AgentStatus.unavailable);
      expect(
        (await h.call('objects', arguments: {'limit': 51})).status,
        AgentStatus.invalid,
      );
    },
  );

  test(
    'agent mutation uses ordinary client operations and registry retry identity',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      final arguments = {
        'source': 'asset',
        'key': 'housing',
        'position': [4, 5, 6],
        'rotation': [0, 0, 0, 1],
        'scale': [1, 1, 1],
      };
      final before = h.provider.revision;
      final result = await h.call(
        'set_transform',
        arguments: arguments,
        write: true,
        expected: before,
        key: 'move',
      );
      expect(result.status, AgentStatus.ok, reason: result.message);
      expect(h.object.position, const Vec3(4, 5, 6));
      expect(h.client.snapshot!.revision, 1);
      expect(result.affectedIds, [target.toString()]);
      final retry = await h.call(
        'set_transform',
        arguments: arguments,
        write: true,
        expected: before,
        key: 'move',
      );
      expect(retry.status, AgentStatus.ok);
      expect(h.client.snapshot!.revision, 1);
      final history = await h.call('history', arguments: {'limit': 1});
      expect(history.status, AgentStatus.ok);
      expect((history.data['records'] as List).length, 1);
      final stale = await h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
        write: true,
        expected: before,
        key: 'stale',
      );
      expect(stale.status, AgentStatus.stale);
      expect(h.object.visible, isTrue);
    },
  );

  test(
    'registry scopes and current authority permissions both gate actions',
    () async {
      final h = CollaborationHarness(grants: {'collaboration.read'});
      await h.start();
      addTearDown(h.close);
      final result = await h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
        write: true,
      );
      expect(result.status, AgentStatus.denied);
      expect(h.client.pending, isNull);
      h.readable = false;
      expect((await h.call('state')).status, AgentStatus.denied);
    },
  );

  test('host permission preview reports an exact allowed operation', () async {
    final h = CollaborationHarness();
    await h.start();
    addTearDown(h.close);
    final operation = SceneOperation(
      sceneId: 'scene',
      epoch: 'epoch',
      operationId: 'preview',
      objectId: target,
      expectedRevision: 0,
      field: SceneField.visibility,
      visible: false,
    );
    h.writable = false;
    final preview = await h.call(
      'check_operation',
      arguments: {'operation': operation.encode()},
    );
    expect(preview.status, AgentStatus.ok);
    expect(preview.data['allowed'], isFalse);
    final result = await h.call(
      'set_visibility',
      arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
      write: true,
    );
    expect(result.status, AgentStatus.denied);
    expect(h.client.pending, isNotNull);
    expect((await h.authority.connect('host-user').read()).revision, 0);
    h.writable = true;
    expect((await h.call('retry_pending', write: true)).status, AgentStatus.ok);
  });

  test(
    'agent conflict is visible and explicit keep_local uses fresh revision',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      await h.authority
          .connect('other')
          .submit(
            SceneOperation(
              sceneId: 'scene',
              epoch: 'epoch',
              operationId: 'external',
              objectId: target,
              expectedRevision: 0,
              field: SceneField.visibility,
              visible: false,
            ),
          );
      final conflict = await h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': true},
        write: true,
      );
      expect(conflict.status, AgentStatus.stale);
      expect(h.client.conflict, isNotNull);
      final state = await h.call('state');
      expect(state.data['conflict'], isNotNull);
      final resolved = await h.call('keep_local', write: true);
      expect(resolved.status, AgentStatus.ok, reason: resolved.message);
      expect(h.object.visible, isTrue);
      expect(h.client.snapshot!.revision, 2);
    },
  );

  test(
    'removed source targets are stale and metadata no longer binds',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      h.scene.remove(h.object);
      final result = await h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
        write: true,
      );
      expect(result.status, AgentStatus.stale);
      expect(h.provider.metadataFor(h.object), isNull);
      expect(h.client.pending, isNull);
    },
  );

  test(
    'cancellation inside async permission wait prevents the authoritative commit',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      h.permissionGate = Completer<void>();
      h.permissionEntered = Completer<void>();
      final cancellation = AgentCancellation();
      final action = h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
        write: true,
        cancellation: cancellation,
      );
      await h.permissionEntered!.future;
      cancellation.cancel();
      h.permissionGate!.complete();
      expect((await action).status, AgentStatus.cancelled);
      expect((await h.authority.connect('host-user').read()).revision, 0);
      expect(h.object.visible, isTrue);
    },
  );

  test('detach cancels the pending action and removes discovery', () async {
    final h = CollaborationHarness();
    await h.start();
    h.permissionGate = Completer<void>();
    h.permissionEntered = Completer<void>();
    final action = h.call(
      'set_visibility',
      arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
      write: true,
    );
    await h.permissionEntered!.future;
    await h.engine.dispose();
    h.permissionGate!.complete();
    expect(
      (await action).status,
      anyOf(AgentStatus.cancelled, AgentStatus.unavailable),
    );
    expect(h.registry.discover()['providers'], isEmpty);
    expect((await h.authority.connect('host-user').read()).revision, 0);
    h.registry.dispose();
    await h.client.close();
  });

  test(
    'rich viewport picks carry collaboration IDs and honest frame coverage',
    () async {
      final h = CollaborationHarness();
      await h.start();
      addTearDown(h.close);
      final mesh = h.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      h.collaboration.binding.rebind({target: mesh});
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      final viewport = AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'saved-scene',
        instanceId: 'view',
        scene: h.scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(200, 100, devicePixelRatio: 3),
        documentRevision: () => h.client.snapshot!.revision,
        metadata: h.provider.metadataFor,
      );
      h.registry.register(viewport);
      final picked = await h.registry.call(
        providerId: viewport.id,
        instanceId: viewport.instanceId,
        tool: 'pick',
        arguments: {'x': 100, 'y': 50},
      );
      expect(picked.status, AgentStatus.ok);
      final hit = (picked.data['hits'] as List).single as Map;
      final object = hit['object'] as Map;
      expect(object['runtimeId'], mesh.id);
      expect((object['metadata'] as Map)['sourceId'], target.toString());
      expect((object['metadata'] as Map)['trust'], 'untrusted-scene-data');
      expect(picked.data['devicePixelRatio'], 3);
      expect(picked.data['documentRevision'], 0);
      expect(picked.data['frameCorrelation'], 'unknown');
      expect(hit['renderedPixelVisibility'], 'unknown');
      expect(hit['worldPoint'], [0.0, 0.0, 0.5]);
      final action = await h.call(
        'set_visibility',
        arguments: {'source': 'asset', 'key': 'housing', 'visible': false},
        write: true,
      );
      expect(action.status, AgentStatus.ok);
      final after = await h.registry.call(
        providerId: viewport.id,
        instanceId: viewport.instanceId,
        tool: 'pick',
        arguments: {'x': 100, 'y': 50},
      );
      expect(after.status, AgentStatus.empty);
      expect(after.data['documentRevision'], 1);
    },
  );

  group('existing engineering review provider', () {
    late Scene scene;
    late Group housing, cover;
    late SceneEngineeringPlugin review;
    late ReviewStore store;
    late EngineeringReviewAgentProvider provider;
    late AgentRegistry registry;
    late SceneEngine engine;
    bool allow = true;
    Future<AgentResult> call(
      String tool, {
      Map<String, Object?> args = const {},
      bool write = false,
      String key = 'action',
      AgentCancellation? cancellation,
    }) => registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: tool,
      arguments: args,
      expectedRevision: provider.revision,
      idempotencyKey: write ? key : null,
      cancellation: cancellation,
    );
    setUp(() async {
      allow = true;
      scene = Scene();
      housing = scene.add(Group());
      cover = scene.add(Group());
      review = SceneEngineeringPlugin(
        document: EngineeringDocument(
          id: 'review',
          objects: [
            EngineeringObject(
              id: 'housing',
              label: 'Housing',
              properties: {'tag': 'P-1', 'secret': 'hidden'},
            ),
            EngineeringObject(id: 'cover', label: 'Cover'),
          ],
          annotations: [
            EngineeringAnnotation(
              id: 'private',
              objectId: 'housing',
              text: 'hidden note',
              anchor: Vec3.zero,
            ),
          ],
        ),
      );
      store = ReviewStore(review.document);
      registry = AgentRegistry(grantedScopes: scopes);
      provider = EngineeringReviewAgentProvider(
        review: review,
        scene: scene,
        instanceId: 'review-main',
        authorize: (_, _) => allow,
        exposedProperties: (object) => {'tag': object.properties['tag']},
        exposeAnnotation: (note) => note.id != 'private',
        sessionStore: store,
        base: store.value,
      );
      engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [
          review,
          EngineeringReviewAgentPlugin(registry: registry, provider: provider),
        ],
      );
      review.bind('housing', housing);
      review.bind('cover', cover);
    });
    tearDown(() async {
      await engine.dispose();
      registry.dispose();
    });

    test(
      'real HTTP and file review adapters persist the provider write',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'zyren-collaboration-review-',
        );
        final fileStore = FileEngineeringSessionStore(
          file: File('${directory.path}/review.json'),
          documentId: 'review',
        );
        final base = await fileStore.initialize(review.document);
        final server = await EngineeringReviewServer.start(
          store: fileStore,
          authorize: (_, _) async => true,
        );
        final http = HttpClient();
        try {
          final shared = EngineeringReviewAgentProvider(
            review: review,
            scene: scene,
            instanceId: 'http-review',
            authorize: (_, _) => true,
            exposedProperties: (_) => {},
            exposeAnnotation: (_) => false,
            sessionStore: HttpEngineeringSessionStore(
              client: http,
              endpoint: server.endpoint,
              headers: () async => {},
            ),
            base: base,
          );
          final registration = registry.register(shared);
          review.putAnnotation(
            EngineeringAnnotation(
              id: 'http-note',
              objectId: 'housing',
              text: 'Persist this',
              anchor: Vec3.zero,
            ),
          );
          final result = await registry.call(
            providerId: shared.id,
            instanceId: shared.instanceId,
            tool: 'synchronize',
            expectedRevision: shared.revision,
            idempotencyKey: 'persist',
          );
          expect(result.status, AgentStatus.ok, reason: result.message);
          final reopened = FileEngineeringSessionStore(
            file: File('${directory.path}/review.json'),
            documentId: 'review',
          );
          final saved = await reopened.read();
          expect(saved.document.annotations['http-note']!.text, 'Persist this');
          expect(saved.version, isNot(base.version));
          registration.dispose();
        } finally {
          http.close(force: true);
          await server.close();
          await directory.delete(recursive: true);
        }
      },
    );

    test(
      'shared discovery and queries expose only host-approved review fields',
      () async {
        expect(
          (registry.discover()['providers'] as List).single['providerId'],
          'zyren.engineering',
        );
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: 'state',
          ),
          isEmpty,
        );
        final result = await call('object', args: {'objectId': 'housing'});
        expect(result.status, AgentStatus.ok, reason: result.message);
        expect(result.data['properties'], {'tag': 'P-1'});
        expect(result.data['annotations'], isEmpty);
        expect(jsonEncode(result.toJson()), isNot(contains('hidden')));
        expect(provider.metadataFor(housing)!.sourceId, 'housing');
        allow = false;
        expect(
          (await call('object', args: {'objectId': 'housing'})).status,
          AgentStatus.denied,
        );
      },
    );

    test(
      'annotation and isolation actions reuse engineering commands',
      () async {
        final added = await call(
          'put_annotation',
          args: {
            'id': 'note',
            'objectId': 'housing',
            'text': 'Check seal',
            'anchor': [0, 1, 0],
          },
          write: true,
          key: 'note',
        );
        expect(added.status, AgentStatus.ok, reason: added.message);
        expect(review.document.annotations['note']!.text, 'Check seal');
        expect(
          (await call(
            'isolate',
            args: {
              'objectIds': ['housing'],
            },
            write: true,
            key: 'isolate',
          )).status,
          AgentStatus.ok,
        );
        expect(cover.visible, isFalse);
        expect(housing.visible, isTrue);
        expect(
          (await call(
            'restore_visibility',
            write: true,
            key: 'restore',
          )).status,
          AgentStatus.ok,
        );
        expect(cover.visible, isTrue);
        expect(
          (await call(
            'remove_annotation',
            args: {'id': 'note'},
            write: true,
            key: 'remove',
          )).status,
          AgentStatus.ok,
        );
        expect(review.document.annotations.containsKey('note'), isFalse);
      },
    );

    test(
      'synchronization uses the existing conditional review write',
      () async {
        review.putAnnotation(
          EngineeringAnnotation(
            id: 'new',
            objectId: 'housing',
            text: 'Shared note',
            anchor: Vec3.zero,
          ),
        );
        final result = await call('synchronize', write: true);
        expect(result.status, AgentStatus.ok, reason: result.message);
        expect(store.writes, 1);
        expect(store.value.document.annotations.containsKey('new'), isTrue);
        expect(result.data['sharedVersion'], '"v1"');
      },
    );

    test('existing three-way conflicts remain explicit and filtered', () async {
      review.putObject(
        EngineeringObject(
          id: 'housing',
          label: 'Local',
          properties: {'secret': 'local secret'},
        ),
      );
      store.value = EngineeringRevision(
        version: '"remote"',
        document: EngineeringDocument(
          id: 'review',
          objects: [
            EngineeringObject(
              id: 'housing',
              label: 'Remote',
              properties: {'secret': 'remote secret'},
            ),
            EngineeringObject(id: 'cover', label: 'Cover'),
          ],
          annotations: store.value.document.annotations.values,
        ),
      );
      final result = await call('synchronize', write: true);
      expect(result.status, AgentStatus.stale);
      expect(store.writes, 0);
      expect(jsonEncode(result.toJson()), isNot(contains('secret')));
      expect(review.document.objects['housing']!.label, 'Local');
    });

    test('cancellation before review write preserves unsaved notes', () async {
      store.gate = Completer<void>();
      final token = AgentCancellation();
      review.putAnnotation(
        EngineeringAnnotation(
          id: 'new',
          objectId: 'housing',
          text: 'Keep this',
          anchor: Vec3.zero,
        ),
      );
      final action = call('synchronize', write: true, cancellation: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      store.gate!.complete();
      expect((await action).status, AgentStatus.cancelled);
      expect(store.writes, 0);
      expect(review.document.annotations.containsKey('new'), isTrue);
    });

    test(
      'removed review targets become stale and detach removes provider',
      () async {
        scene.remove(housing);
        expect(
          (await call(
            'isolate',
            args: {
              'objectIds': ['housing'],
            },
            write: true,
          )).status,
          AgentStatus.stale,
        );
        await engine.dispose();
        expect(registry.discover()['providers'], isEmpty);
      },
    );
  });
}
