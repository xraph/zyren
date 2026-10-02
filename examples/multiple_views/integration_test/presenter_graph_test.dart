import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:flutter_zyren/src/presentation/native_android_presenter.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/zyren_native/test/support/graph_checks.dart';

class _ComputePlugin extends ScenePlugin {
  @override
  String get id => 'presenter.compute';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.compute,
  };
  late ResourceScope resources;
  late GraphCompiler compiler;
  late GpuResource<Buffer> output;
  late CompiledGraph graph;
  int frames = 0;
  @override
  Future<void> attach(PluginContext context) async {
    resources = context.resources;
    compiler = context.graphs;
    output = await resources.createBuffer(
      BufferDescriptor(
        size: 16,
        usage: {BufferUsage.storage, BufferUsage.copySource},
      ),
    );
    final source = ShaderSource.wgsl(
      '// 🌍\n@compute fn invalid() { ? }',
      label: 'diagnostic.wgsl',
    );
    await expectLater(
      context.shaders.compile(source),
      throwsA(
        isA<ShaderCompilationException>()
            .having((e) => e.source.label, 'source', 'diagnostic.wgsl')
            .having((e) => e.diagnostics.first.location!.line, 'line', 2),
      ),
    );
    final program = await context.shaders.compile(
      ShaderSource.wgsl('''
      @group(0) @binding(0) var<storage, read_write> values: array<u32>;
      @compute @workgroup_size(1) fn main() { values[0] = 42u; }
    '''),
    );
    graph = await compiler.compile(
      GraphDescription(
        inputs: [output],
        passes: [
          ComputePassDescriptor(
            name: 'plugin.update',
            program: program,
            workgroups: const Workgroups(1),
            bindings: ShaderBindings([
              BufferBinding.storageReadWrite(0, output),
            ]),
            reads: [output],
            writes: [output],
          ),
        ],
      ),
    );
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    await graph.execute();
    final bytes = await resources.readBuffer(output);
    expect(ByteData.sublistView(bytes).getUint32(0, Endian.little), 42);
    frames++;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = Platform.isAndroid;
  Future<NativeGpuBackend> create() async =>
      android ? NativeAndroidBackend.create() : NativeMetalBackend.create();
  final channel = MethodChannel(
    android ? 'zyren/android-surfaces' : 'zyren/scene-views',
  );

  testWidgets(
    'native presenter runs compute-to-render textures and typed buffer bindings',
    (tester) async {
      await verifyNativeGraph(providedBackend: await create());
      await verifyNativeGraphBuffers(providedBackend: await create());
      final stats = (await channel.invokeMapMethod<Object?, Object?>(
        'diagnostics',
      ))!;
      expect(stats['sessions'], 0);
      expect(stats['renderers'], 0);
    },
  );

  testWidgets(
    'plugin GPU work shares the presenter device and preserves scene rendering',
    (tester) async {
      final backend = await create();
      final plugin = _ComputePlugin();
      final engine = await SceneEngine.create(
        scene: Scene()..background = const Color3(1, 0, 0),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
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
        expect(plugin.frames, 1);
        if (android) {
          expect(output, isA<PresentedOutput>());
          expect(output.stats.readbackBytes, 0);
          await presenter!.present(output);
        } else {
          expect((output as ReadbackOutput).image.pixels.sublist(0, 4), [
            255,
            0,
            0,
            255,
          ]);
        }
        final session = android
            ? (backend as NativeAndroidBackend).session
            : (backend as NativeMetalBackend).session;
        for (final (kind, capacity) in [
          ('shader', 1),
          ('graph', -1),
          ('resource', 67108889),
          ('unknown', 24),
        ]) {
          await expectLater(
            channel.invokeMethod<Object?>('gpuCommand', {
              'session': session,
              'kind': kind,
              'bytes': Uint8List(1),
              'capacity': capacity,
            }),
            throwsA(isA<PlatformException>()),
          );
        }
        expect((await backend.graphStats()).liveGraphs, 1);
        expect((await backend.resourceStats()).residentBytes, 16);
      } finally {
        await presenter?.dispose();
        await engine.dispose();
      }
      expect(plugin.graph.isClosed, isTrue);
      expect(plugin.resources.isClosed, isTrue);
      final stats = (await channel.invokeMapMethod<Object?, Object?>(
        'diagnostics',
      ))!;
      expect(stats['sessions'], 0);
      expect(stats['renderers'], 0);
      expect(stats[android ? 'surfaces' : 'heldDrawables'], 0);
    },
  );
}
