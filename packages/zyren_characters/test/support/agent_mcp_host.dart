// Qualification host: real imported assets and Rapier, substituted renderer.
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import '../../example/walkthrough_agents.dart';
import '../../example/walkthrough_scene.dart';
import '../../../zyren/test/support/fakes.dart';

Future<void> main() async {
  final demo = await WalkthroughScene.load();
  final registry = AgentRegistry(grantedScopes: {'characters.playback'});
  final inspector = SceneDevtoolsPlugin();
  final camera = PerspectiveCamera(position: const Vec3(1.8, 1.05, 5));
  camera.lookAt(const Vec3(1.8, 1.05, .2));
  final engine = await SceneEngine.create(
    scene: demo.scene,
    camera: camera,
    rendererFactory: () async => TestRenderer([]),
    plugins: [
      demo.timeline,
      demo.character,
      inspector,
      WalkthroughAgents(demo, registry),
    ],
  );
  final bridge = AgentDevtoolsBridge(registry),
      diagnostics = SceneDiagnostics(inspector);
  try {
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, arguments) async => AgentDevtoolsBridge.accepts(name)
          ? bridge.call(name, arguments)
          : diagnostics.call(name, arguments),
    );
  } finally {
    await engine.dispose();
    registry.dispose();
    await demo.close();
  }
}
