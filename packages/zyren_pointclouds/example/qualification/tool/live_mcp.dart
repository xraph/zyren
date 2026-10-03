import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/streaming.dart';
import 'package:zyren_pointclouds/stream_agents.dart';
import 'package:zyren_splats/zyren_splats.dart';
import 'package:zyren_splats/stream_agents.dart';
import 'package:zyren_splats/streaming.dart';

/// Host-started stdio MCP using the shared devtools protocol. EOF closes all work.
Future<void> main(List<String> args) async {
  final scene = Scene(),
      camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  final data = PointCloudData(
    sourceUri: Uri.parse('memory:mcp-survey'),
    sourceVersion: 'fixture-v1',
    points: [const Vec3(-.5, 0, 0), const Vec3(.5, 0, 0)],
    classifications: [2, 7],
  );
  final tree = PointCloudOctree.fromData(data, samplesPerChunk: 1);
  final points = PointCloudStreamPlugin(
    stream: SpatialStreamer(root: tree.root, loader: tree.load),
  );
  final gaussianData = GaussianCloudData(
    sourceUri: Uri.parse('memory:mcp-Gaussian'),
    sourceVersion: 'fixture-v1',
    splats: [
      GaussianSplat(
        mean: Vec3.zero,
        covariance: GaussianCovariance(xx: .05, yy: .02, zz: .01),
        color: const Color3(1, 0, 0),
      ),
    ],
  );
  final gaussianTree = GaussianOctree.fromData(gaussianData);
  final gaussian = GaussianStreamPlugin(
    stream: SpatialStreamer(
      root: gaussianTree.root,
      loader: gaussianTree.load,
      budget: const SpatialStreamBudget(maxGpuBytes: 184 * 8),
    ),
  );
  final inspector = SceneDevtoolsPlugin();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    backendFactory: NativeBackend.create,
    plugins: [points, gaussian, inspector],
  );
  final registry = AgentRegistry(
    grantedScopes: args.contains('--allow-filter')
        ? {'pointclouds.filter'}
        : {},
  );
  final bridge = AgentDevtoolsBridge(registry),
      diagnostics = SceneDiagnostics(inspector);
  final view = AgentViewportProvider(
    sceneId: 'capture-scene',
    documentId: 'qualification',
    instanceId: 'main',
    scene: scene,
    camera: () => camera,
    viewport: () => const ViewportMetrics(128, 128),
  );
  Future<void> render() async {
    await engine.render(elapsed: Duration.zero, width: 128, height: 128);
    await points.stream.settle();
    await gaussian.stream.settle();
    await engine.render(elapsed: Duration.zero, width: 128, height: 128);
  }

  try {
    await render();
    registry.register(view);
    PointCloudStreamAgentProvider(
      plugin: points,
      view: view,
      instanceId: 'points',
    ).register(registry);
    GaussianStreamAgentProvider(
      plugin: gaussian,
      view: view,
      instanceId: 'gaussians',
    ).register(registry);
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, arguments) async {
        if (AgentDevtoolsBridge.accepts(name)) {
          final result = await bridge.call(name, arguments);
          if (name == 'agent_command') await render();
          return result;
        }
        return diagnostics.call(name, arguments);
      },
    );
  } finally {
    bridge.dispose();
    await engine.dispose();
    final remaining = (registry.discover()['providers'] as List).length;
    if (remaining != 1) throw StateError('Scene providers did not unregister.');
    registry.dispose();
    if (gaussian.stream.stats.decodedBytes != 0) {
      throw StateError('Gaussian stream did not close.');
    }
    stderr.writeln(
      'REALITY_MCP_CLEANUP decoded=${points.stream.stats.decodedBytes} requests=${points.stream.stats.activeRequests}',
    );
  }
}
