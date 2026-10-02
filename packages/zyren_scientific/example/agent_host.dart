import 'dart:convert';
import 'dart:io';

import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_scientific/agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

import 'support/png.dart';
import 'synthetic_slice.dart' show syntheticField;

/// Explicit host using the shared devtools MCP protocol over stdio. No listener.
/// The viewport represents an offscreen native capture, not a presented window.
Future<void> main(List<String> args) async {
  final output = Directory(
    args.isEmpty ? '/tmp/zyren-scientific-evidence/mcp' : args.single,
  );
  await output.create(recursive: true);
  final field = syntheticField();
  final scene = Scene()..background = const Color3(.02, .025, .035);
  final view = ScientificSliceView(
    id: 'synthetic-temperature',
    scene: scene,
    slice: ScalarSlice.build(
      grid: field,
      axis: SliceAxis.z,
      index: 1.5,
      coordinateTolerance: 1e-6,
      transfer: ScalarTransferFunction(
        unit: field.valueUnit,
        minimum: 273.15,
        maximum: 313.15,
        stops: [
          TransferStop(0, const Color3(0, 0, 1)),
          TransferStop(1, const Color3(1, 0, 0)),
        ],
      ),
    ),
    coordinateTolerance: 1e-6,
  );
  final camera = OrthographicCamera(
    position: const Vec3(.5, .5, 5),
    target: const Vec3(.5, .5, 0),
    left: -.65,
    right: .65,
    bottom: -.65,
    top: .65,
  );
  final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
  registerScientificView(registry, view);
  final provider = ScientificAgentProvider(view);
  final backend = await NativeBackend.create();
  var captureId = 0;
  final bridge = AgentDevtoolsBridge(registry);
  registry.register(
    AgentViewportProvider(
      sceneId: 'synthetic-scene',
      documentId: 'synthetic-document',
      instanceId: 'capture-view',
      scene: scene,
      camera: () => camera,
      viewport: () => const ViewportMetrics(640, 640),
      units: 'm',
      metadata: provider.metadata,
      hostState: () => {
        'presentation': 'offscreen-native-readback',
        'synthetic': true,
        'backend': backend.capabilities.backend,
        'captureId': captureId,
        'captureSceneRevision': scene.revision,
        'capturePath': '${output.path}/synthetic-$captureId.png',
        'overlays': [],
        'focus': 'unavailable-offscreen',
      },
    ),
  );
  Future<void> capture() async {
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(640, 640),
              ),
            )
            as ReadbackOutput;
    captureId++;
    await File(
      '${output.path}/synthetic-$captureId.png',
    ).writeAsBytes(png(frame.image));
    await File('${output.path}/capture.json').writeAsString(
      jsonEncode({
        'synthetic': true,
        'captureId': captureId,
        'sceneRevision': scene.revision,
        'viewRevision': view.revision,
        'cameraRevision': camera.revision,
        'backend': backend.capabilities.backend,
        'adapter': backend.capabilities.adapterName,
        'nativeFrameId': frame.stats.frameId,
        'presentation': 'readback',
      }),
    );
  }

  try {
    await capture();
    stderr.writeln(
      'SYNTHETIC scalar host: ${backend.capabilities.backend}, offscreen capture; no presented frame.',
    );
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, arguments) async {
        if (!AgentDevtoolsBridge.accepts(name)) {
          throw const DiagnosticException(
            'unavailable',
            'This host has no diagnostics attachment.',
          );
        }
        final before = view.revision;
        final result = await bridge.call(name, arguments);
        if (view.revision != before) await capture();
        return result;
      },
    );
  } finally {
    view.dispose();
    registry.dispose();
    await backend.close();
  }
}
