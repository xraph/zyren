import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_pipeline/agents.dart';
import 'package:zyren_pipeline/gltf_metadata.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'triangle_source.dart';

/// Uses the existing stdio transport. Stdout is reserved for MCP messages.
Future<void> main(List<String> args) async {
  final source = TriangleSource();
  final bundle = await PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
  final runtime = PipelineRuntime(
    cache: PipelineCache()..put(bundle),
    services: AssetServices(),
  );
  final loaded = runtime.start(
    bundleVersion: bundle.version,
    kind: PipelineJobKind.load,
  );
  await loaded.done;
  final instance = loaded.model!.instantiate();
  final scene = Scene()..add(instance);
  final camera = PerspectiveCamera(
    position: const Vec3(.25, .25, 5),
    target: const Vec3(.25, .25, 0),
  );
  final metadata = PipelineGltfMetadata(
    bundleVersion: bundle.version,
    sourceId: 'model',
    sourceRevision: bundle.resource('model').source.revision,
    instance: instance,
    sourceIds: {0: 'part:triangle'},
  );
  final registry = AgentRegistry(
    grantedScopes: {'pipeline.load', 'pipeline.jobs', 'pipeline.cache.write'},
  );
  final attachment = PipelineAgentProvider(
    runtime: runtime,
    instanceId: 'assets',
  ).attach(registry);
  NativeBackend? backend;
  if (args.contains('--native')) {
    backend = await NativeBackend.create();
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(200, 100),
              ),
            )
            as ReadbackOutput;
    stderr.writeln(
      'Native readback ${backend.capabilities.backend}: ${frame.image.pixels.length} bytes',
    );
  }
  registry.register(
    AgentViewportProvider(
      sceneId: 'pipeline-scene',
      documentId: 'pipeline-document',
      instanceId: 'main-view',
      scene: scene,
      camera: () => camera,
      viewport: () => const ViewportMetrics(200, 100),
      metadata: (object) => pipelineGltfAgentMetadata(metadata, object),
    ),
  );
  final bridge = AgentDevtoolsBridge(registry);
  try {
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, arguments) {
        if (!AgentDevtoolsBridge.accepts(name)) {
          throw const DiagnosticException(
            'unavailable',
            'This host exposes the registered pipeline and viewport.',
          );
        }
        return bridge.call(name, arguments);
      },
    );
  } finally {
    attachment.dispose();
    await runtime.close();
    registry.dispose();
    await backend?.close();
  }
}
