import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:flutter_gpu3d/src/presentation/native_android_presenter.dart';
import 'package:flutter_gpu3d/src/presentation/native_metal_presenter.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/gpu3d_native/test/support/frame_graph_checks.dart';

class Effects extends ScenePlugin {
  @override
  String get id => 'effects';
  @override
  Set<RenderFeature> get requiredFeatures => {RenderFeature.frameGraphs};
  late CompiledGraph graph;
  @override
  Future<void> attach(PluginContext context) async {
    final binding = context.frameGraph;
    graph = await compileFrameEffect(
      context.resources,
      context.shaders,
      context.graphs,
      17,
      13,
      compute: true,
    );
    binding.graph = graph;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native frame graph pixels and plugin surface composition', (
    tester,
  ) async {
    await verifyFrameGraph();
    await verifyFrameGraph(compute: true);
    if (Platform.isMacOS) {
      await verifyFrameGraph(
        providedBackend: await NativeMetalBackend.create(),
      );
    }
    final android = Platform.isAndroid;
    final NativeGpuBackend backend = android
        ? await NativeAndroidBackend.create()
        : await NativeMetalBackend.create();
    final effects = Effects();
    final engine = await SceneEngine.create(
      scene: Scene()..background = const Color3(1, 0, 0),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: [effects],
    );
    final presenter = android
        ? const NativeAndroidPresenterFactory().create(backend)
        : null;
    try {
      final target =
          await presenter?.prepare(PhysicalSize(17, 13)) ??
          const ReadbackTarget();
      final output = await engine.renderFrame(
        target: target,
        elapsed: Duration.zero,
        width: 17,
        height: 13,
      );
      if (android) {
        expect(output, isA<PresentedOutput>());
        expect(output.stats.readbackBytes, 0);
        await presenter!.present(output);
      } else {
        expect((output as ReadbackOutput).image.pixels.sublist(0, 4), [
          255,
          0,
          255,
          255,
        ]);
      }
    } finally {
      await presenter?.dispose();
      await engine.dispose();
    }
    expect(effects.graph.isClosed, isTrue);
    final stats = (await MethodChannel(
      android ? 'gpu3d/android-surfaces' : 'gpu3d/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics'))!;
    expect(stats['sessions'], 0);
    expect(stats['renderers'], 0);
    expect(stats[android ? 'surfaces' : 'heldDrawables'], 0);
  });
}
