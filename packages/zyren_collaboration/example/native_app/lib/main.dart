import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/agent_provider.dart';
import 'package:zyren_collaboration/file_store.dart';
import 'package:zyren_collaboration/network.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';

String uniqueId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
final sourceId = SceneObjectId(source: 'demo-box@1', key: 'housing');
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(
        useMaterial3: true,
      ).copyWith(visualDensity: VisualDensity.compact),
      home: FutureBuilder<DemoSession>(
        future: DemoSession.open(
          Directory(
            '${Platform.environment['HOME']}/Library/Application Support/zyren-collaboration-demo',
          ),
        ),
        builder: (_, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: ZeroState(
                title: 'Scene could not open',
                message: '${snapshot.error}',
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return CollaborationDemo(session: snapshot.data!);
        },
      ),
    ),
  );
}

/// The example hosts one authority locally. Production hosts supply their own
/// credential provider and TLS endpoint; the scene files contain neither.
final class DemoSession extends ChangeNotifier {
  final Directory directory;
  late final DurableSceneAuthority authority;
  late final SceneCollaborationServer server;
  late final HttpSceneTransport http;
  late final WebSocketSceneTransport socket;
  late final SceneCollaborationClient alice, bob;
  late final OfflineSceneQueue outbox;
  late final ScenePresenceAuthority presence;
  late final SceneController left, right;
  late final SceneCollaborationPlugin leftPlugin, rightPlugin;
  late final NativeAgentHost agents;
  late final SharedCameraFollower follower;
  late final Mesh leftBox, rightBox;
  final _sessionId = uniqueId();
  int _sequence = 0;
  int? lastAliceRevision;
  bool offline = false, busy = false, _closed = false;
  String? error;
  OfflineSceneState? queue;
  List<ScenePresence> participants = [];
  Timer? _heartbeat;
  StreamSubscription<void>? _network;
  bool _refreshing = false;
  DemoSession._(this.directory);
  static Future<DemoSession> open(Directory directory) async {
    final demo = DemoSession._(directory);
    await demo._start();
    return demo;
  }

  Future<void> _start() async {
    authority = DurableSceneAuthority(
      store: FileSceneDocumentStore(File('${directory.path}/scene.json')),
      canRead: (who, _) => {'alice', 'bob'}.contains(who),
      canWrite: (who, _, _) => {'alice', 'bob'}.contains(who),
    );
    await authority.initialize(
      SceneSnapshot(
        sceneId: 'shared-demo',
        epoch: 'asset-1',
        objects: [SceneObjectState(id: sourceId)],
      ),
    );
    final credentials = {uniqueId(): 'alice', uniqueId(): 'bob'};
    presence = ScenePresenceAuthority(
      authorize: (who) async {
        await authority.connect(who).read();
        return true;
      },
    );
    server = await SceneCollaborationServer.bind(
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      authenticate: (request) =>
          credentials[request.headers.value('authorization')],
      connect: authority.connect,
      presence: presence,
    );
    http = HttpSceneTransport(
      endpoint: server.endpoint,
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      headers: () => {'authorization': credentials.keys.first},
    );
    socket = WebSocketSceneTransport(
      endpoint: server.endpoint.replace(scheme: 'ws'),
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      headers: () => {'authorization': credentials.keys.last},
    );
    alice = SceneCollaborationClient(
      transport: authority.connect('alice'),
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      nextOperationId: uniqueId,
    );
    bob = SceneCollaborationClient(
      transport: socket,
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      nextOperationId: uniqueId,
    );
    await alice.refresh();
    await bob.refresh();
    outbox = OfflineSceneQueue(
      store: FileSceneDocumentStore(
        File('${directory.path}/alice-outbox.json'),
      ),
      transport: http,
      sceneId: 'shared-demo',
      epoch: 'asset-1',
      ownerId: 'alice',
    );
    await outbox.initialize(alice.snapshot!);
    queue = await outbox.read();
    leftPlugin = SceneCollaborationPlugin(alice);
    rightPlugin = SceneCollaborationPlugin(bob);
    SceneController viewport(SceneCollaborationPlugin plugin, bool first) {
      final scene = Scene()..background = Color3.hex(0x161e28);
      final box = scene.add(
        Mesh(
          BoxGeometry(width: .9, height: .9, depth: .9),
          UnlitMaterial(color: Color3.hex(0xefac65)),
          name: 'Housing',
        ),
      );
      if (first) {
        leftBox = box;
      } else {
        rightBox = box;
      }
      final controller = SceneController(
        scene: scene,
        camera: PerspectiveCamera(position: const Vec3(2, 1.4, 5)),
        runtime: Platform.isMacOS || Platform.isIOS
            ? const SceneRuntime.nativeMetal()
            : const SceneRuntime.nativeAndroid(),
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      );
      controller.use(plugin);
      controller.use(BindScene(plugin, box));
      return controller;
    }

    left = viewport(leftPlugin, true);
    right = viewport(rightPlugin, false);
    follower = SharedCameraFollower(
      apply: (camera) {
        right.camera = camera;
        right.invalidate();
      },
    );
    agents = NativeAgentHost(this);
    left.use(agents.inspector);
    left.use(agents);
    _network = socket.changes.listen((_) {
      if (!busy) unawaited(refresh());
    });
    await heartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!busy) {
        unawaited(
          heartbeat().catchError((Object e) {
            if (!_closed) {
              error = '$e';
              notifyListeners();
            }
          }),
        );
      }
    });
  }

  Future<void> heartbeat() async {
    if (_closed) return;
    await socket.publishPresence(
      sessionId: 'bob-$_sessionId',
      label: 'Bob',
      sequence: ++_sequence,
      camera: SharedSceneCamera.capture(right.camera),
      selection: sourceId,
    );
    if (!offline) {
      await http.publishPresence(
        sessionId: 'alice-$_sessionId',
        label: 'Alice',
        sequence: ++_sequence,
        camera: SharedSceneCamera.capture(left.camera),
        selection: sourceId,
      );
    }
    participants = await socket.participants();
    follower.update(participants);
    if (!_closed) notifyListeners();
  }

  Future<void> refresh() async {
    if (_closed || _refreshing) return;
    _refreshing = true;
    try {
      if (!offline && !alice.isBusy) await alice.refresh();
      if (!bob.isBusy) await bob.refresh();
      queue = await outbox.read();
      participants = await socket.participants();
      follower.update(participants);
      if (!_closed) notifyListeners();
    } catch (e) {
      if (!_closed) {
        error = '$e';
        notifyListeners();
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy || _closed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      error = '$e';
    } finally {
      busy = false;
      await refresh();
      if (!_closed) notifyListeners();
    }
  }

  Future<void> moveAlice() async {
    if ((await outbox.read()).pending.isEmpty && !offline) {
      await outbox.reconcile();
    }
    final state = await outbox.read(),
        object = (await outbox.read()).snapshot.objects[sourceId]!;
    await outbox.enqueue(
      SceneOperation(
        sceneId: state.snapshot.sceneId,
        epoch: state.snapshot.epoch,
        operationId: uniqueId(),
        objectId: sourceId,
        expectedRevision: object.transformRevision,
        field: SceneField.transform,
        transform: SceneTransform(
          position: object.transform.position + const Vec3(.3, 0, 0),
        ),
      ),
    );
    if (!offline) await synchronize();
  }

  Future<void> moveBob() async {
    await bob.refresh();
    bob.setTransform(
      sourceId,
      SceneTransform(
        position:
            bob.snapshot!.objects[sourceId]!.transform.position +
            const Vec3(-.3, 0, 0),
      ),
    );
    await bob.flush();
  }

  Future<void> synchronize() async {
    if (offline) throw StateError('Reconnect Alice before synchronizing.');
    final pending = (await outbox.read()).pending;
    queue = await outbox.reconcile();
    if (queue!.pending.isEmpty && pending.isNotEmpty) {
      final receipt = await http.submit(pending.last);
      if (receipt is SceneOperationAccepted) {
        lastAliceRevision = receipt.committedRevision;
      }
    }
    if (queue!.lastError != null) error = queue!.lastError;
  }

  Future<void> toggleOffline() async {
    offline = !offline;
    if (offline) {
      await http.leave('alice-$_sessionId');
    } else {
      await synchronize();
      await heartbeat();
    }
  }

  Future<void> followAlice() async {
    final person = participants.where((p) => p.label == 'Alice').firstOrNull;
    if (person == null) throw StateError('Alice has no active camera lease.');
    follower.follow(person.sessionId);
    follower.update(participants);
  }

  Future<void> orbitAlice() async {
    left.camera.position = left.camera.position + const Vec3(.5, .2, 0);
    left.invalidate();
    await heartbeat();
  }

  Future<void> undoAlice() async {
    if (lastAliceRevision == null) {
      throw StateError('Move Alice before undoing.');
    }
    final result = await http.undo(
      revision: lastAliceRevision!,
      operationId: uniqueId(),
    );
    if (result is SceneOperationConflict) {
      throw StateError(
        'Another edit changed this field. Undo was not applied.',
      );
    }
    lastAliceRevision = (result as SceneOperationAccepted).committedRevision;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    await _network?.cancel();
    follower.close();
    left.dispose();
    right.dispose();
    await Future.wait([left.whenDisposed, right.whenDisposed]);
    await alice.close();
    await bob.close();
    await http.close();
    await socket.close();
    await server.close();
    dispose();
  }
}

final class BindScene extends ScenePlugin {
  final SceneCollaborationPlugin collaboration;
  final Mesh box;
  BindScene(this.collaboration, this.box);
  @override
  String get id => 'demo.bind';
  @override
  Set<String> get dependencies => {collaboration.id};
  @override
  void attach(PluginContext context) =>
      collaboration.binding.rebind({sourceId: box});
}

final class NativeAgentHost extends ScenePlugin {
  final DemoSession demo;
  final inspector = SceneDevtoolsPlugin();
  late AgentRegistry registry;
  late CollaborationAgentProvider provider;
  AgentPresentedFrame? frame;
  DevtoolsServer? bridge;
  NativeAgentHost(this.demo);
  @override
  String get id => 'demo.agents';
  @override
  Set<String> get dependencies => {
    'zyren.collaboration',
    'zyren.devtools',
    'demo.bind',
  };
  @override
  void attach(PluginContext context) {
    registry = AgentRegistry(
      grantedScopes: {
        'collaboration.read',
        'collaboration.write',
        'collaboration.camera',
      },
    );
    context.scope.keep(Registration(registry.dispose));
    provider = CollaborationAgentProvider(
      client: demo.alice,
      binding: demo.leftPlugin.binding,
      instanceId: 'main',
      documentId: 'shared-demo',
      presence: demo.presence.connect('alice'),
      offline: demo.outbox,
      cameraFollower: demo.follower,
    );
    final viewport = AgentViewportProvider(
      sceneId: 'shared-demo',
      documentId: 'shared-demo',
      instanceId: 'main',
      scene: demo.left.scene,
      camera: () => demo.left.camera,
      viewport: () => (demo.left.input as ViewportInputSource).viewport,
      documentRevision: () => demo.alice.snapshot!.revision,
      presentedFrame: () => frame,
      metadata: provider.metadataFor,
      hostState: () => {
        'offline': demo.offline,
        'pending': demo.queue?.pending.length,
        'cameraFollowing': demo.follower.sessionId,
        'activeViewport': true,
        'focus': 'unknown',
        'overlays': [],
      },
    );
    for (final service in [
      provider,
      viewport,
      DiagnosticsAgentProvider(
        diagnostics: SceneDiagnostics(inspector),
        inspector: inspector,
        instanceId: 'main',
      ),
    ]) {
      context.scope.keep(registry.register(service));
    }
    context.scope.listen(demo.left.presentations, (sample) {
      frame = AgentPresentedFrame(
        id: '${sample.frame.frameId}',
        presentedAt: 'controller+${sample.elapsed.inMicroseconds}us',
      );
    });
  }

  Future<DevtoolsServer> startBridge() async => bridge ??=
      await DevtoolsServer.start(SceneDiagnostics(inspector), agents: registry);
  @override
  Future<void> detach(PluginContext context) async {
    await bridge?.close();
    bridge = null;
  }
}

class CollaborationDemo extends StatelessWidget {
  final DemoSession session;
  final Widget Function(SceneController)? viewportBuilder;
  const CollaborationDemo({
    super.key,
    required this.session,
    this.viewportBuilder,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final d = session;
      Widget button(String label, Future<void> Function() action) =>
          OutlinedButton(
            onPressed: d.busy ? null : () => unawaited(d.act(action)),
            child: Text(label),
          );
      Widget panel(String title, SceneController controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(title),
          ),
          Expanded(
            child: Listener(
              onPointerDown: (_) {
                if (identical(controller, d.right)) d.follower.stop();
              },
              child:
                  viewportBuilder?.call(controller) ??
                  SceneView(controller: controller),
            ),
          ),
        ],
      );
      return Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Shared scene',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('Revision ${d.alice.snapshot!.revision}'),
                    Text('${d.participants.length} present'),
                    Text('${d.queue?.pending.length ?? 0} queued'),
                    Text(d.offline ? 'Alice offline' : 'Connected'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    button('Move Alice', d.moveAlice),
                    button('Move Bob', d.moveBob),
                    button(
                      d.offline ? 'Reconnect' : 'Go offline',
                      d.toggleOffline,
                    ),
                    button('Sync', d.synchronize),
                    button('Undo Alice', d.undoAlice),
                    button('Follow Alice', d.followAlice),
                    button('Orbit Alice', d.orbitAlice),
                  ],
                ),
              ),
              if (d.queue?.conflict != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Transform conflict. Choose which edit to keep.',
                      ),
                      button('Keep mine', () async {
                        await d.outbox.keepLocal(
                          uniqueId(),
                          reviewed: d.queue!.conflict!,
                        );
                        await d.synchronize();
                      }),
                      button('Use remote', () async {
                        await d.outbox.acceptRemote(
                          reviewed: d.queue!.conflict!,
                        );
                        await d.synchronize();
                      }),
                    ],
                  ),
                ),
              if (d.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Text(
                    d.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, bounds) => Flex(
                    direction: bounds.maxWidth < 650
                        ? Axis.vertical
                        : Axis.horizontal,
                    children: [
                      Expanded(
                        child: panel('Alice · durable HTTP edits', d.left),
                      ),
                      Expanded(
                        child: panel(
                          'Bob · WebSocket updates${d.follower.sessionId == null ? '' : ' · following'}',
                          d.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
