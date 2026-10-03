import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_scientific/agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
// Share the pure Dart fixture without a dependency on the Flutter application.
// ignore: avoid_relative_lib_imports
import 'flutter/lib/fixtures.dart';
import 'support/png.dart';

/// Shared stdio MCP transport with actual native captures after field commands.
Future<void> main(List<String> args) async {
  final output = Directory(
    args.isEmpty ? '/tmp/zyren-scientific-evidence/field-mcp' : args.single,
  );
  await output.create(recursive: true);
  final backend = await NativeBackend.create();
  final scene = Scene()..background = const Color3(.01, .015, .025);
  final camera = PerspectiveCamera(
    position: const Vec3(2.5, 1.8, 3.5),
    target: Vec3.zero,
    near: .05,
    far: 50,
  );
  final plugin = ScientificVolumePlugin();
  final engine = await SceneEngine.create(
    scene: scene,
    camera: camera,
    backendFactory: () async => backend,
    plugins: [plugin],
  );
  final temporal = syntheticTime();
  final view = ScientificFieldView(
    id: 'native-field',
    scene: scene,
    grid: syntheticField(),
    transfer: syntheticTransfer(),
    coordinateTolerance: 1e-5,
    scalarTolerance: 2e-5,
    vectors: syntheticVectors(),
    temporal: temporal,
    volume: plugin.controller,
  );
  final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
  final provider = ScientificFieldAgentProvider(view);
  registerScientificField(registry, view);
  var frameId = 0;
  registry.register(
    AgentViewportProvider(
      sceneId: 'synthetic-scientific-scene',
      documentId: 'synthetic-fields-v1',
      instanceId: 'capture-view',
      scene: scene,
      camera: () => camera,
      viewport: () => const ViewportMetrics(640, 640),
      metadata: provider.metadata,
      units: 'm',
      hostState: () => {
        'presentation': 'offscreen-native-readback',
        'backend': backend.capabilities.backend,
        'captureId': frameId,
        'synthetic': true,
      },
    ),
  );
  final bridge = AgentDevtoolsBridge(registry);
  Future<void> capture() async {
    final frame =
        await engine.renderFrame(
              elapsed: Duration(milliseconds: frameId * 16),
              width: 640,
              height: 640,
            )
            as ReadbackOutput;
    frameId++;
    await File(
      '${output.path}/field-$frameId.png',
    ).writeAsBytes(png(frame.image));
    await File('${output.path}/capture.json').writeAsString(
      jsonEncode({
        'captureId': frameId,
        'nativeFrameId': frame.stats.frameId,
        'backend': backend.capabilities.backend,
        'adapter': backend.capabilities.adapterName,
        'presentation': 'offscreen-native-readback',
        ...view.describe(),
      }),
    );
  }

  try {
    await view.configure(
      expectedRevision: 0,
      sliceIndex: 10,
      threshold: 293,
      seed: const Vec3(.4, 1, 1),
      vectorScale: .2,
    );
    await capture();
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, arguments) async {
        final before = view.revision;
        final result = await bridge.call(name, arguments);
        if (view.revision != before) await capture();
        return result;
      },
    );
  } finally {
    await view.dispose();
    await temporal.dispose();
    registry.dispose();
    await engine.dispose();
  }
}
