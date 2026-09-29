import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'render_graph_test.dart' show Device;

void main() {
  late Device device;
  late ResourceScope resources;
  late ShaderCompiler shaders;
  late GraphCompiler compiler;
  late ShaderProgram program;
  late GpuResource<Texture> scene, output;
  setUp(() async {
    device = Device();
    resources = ResourceScope(device);
    shaders = ShaderCompiler(device);
    compiler = GraphCompiler(device);
    program = await shaders.compile(ShaderSource.wgsl('valid'));
    scene = await resources.createTexture(
      TextureDescriptor(
        width: 17,
        height: 13,
        label: 'scene',
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
    output = await resources.createTexture(
      TextureDescriptor(
        width: 17,
        height: 13,
        label: 'output',
        usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
      ),
    );
  });
  tearDown(() async {
    await compiler.close();
    await shaders.close();
    await resources.close();
  });
  GraphDescription description({bool discard = false}) => GraphDescription(
    sceneColor: scene,
    output: output,
    passes: [
      RenderPassDescriptor(
        name: 'effect',
        program: program,
        color: ColorAttachment(
          output,
          store: discard ? AttachmentStore.discard : AttachmentStore.store,
        ),
        bindings: ShaderBindings([TextureBinding.sampled(0, scene)]),
        reads: [scene],
        writes: [output],
      ),
    ],
  );
  test(
    'plugin frame binding is selected after hooks and stops at scope close',
    () async {
      final graph = await compiler.compile(description());
      final backend = FrameBackend();
      final plugin = FramePlugin('effects', graph);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      await engine.renderFrame(elapsed: Duration.zero, width: 17, height: 13);
      expect(backend.last?.graph, same(graph));
      plugin.context.scope.close();
      expect(() => plugin.binding.graph = graph, throwsStateError);
      // Teardown closes the binding without assuming ownership of its compiler.
      await engine.dispose();
      expect(plugin.binding.graph, isNull);
    },
  );
  test(
    'a view rejects a second frame graph provider and unsupported devices',
    () async {
      final graph = await compiler.compile(description());
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => FrameBackend(),
          plugins: [FramePlugin('a', graph), FramePlugin('b', graph)],
        ),
        throwsStateError,
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => FrameBackend(supported: false),
          plugins: [FramePlugin('a', graph)],
        ),
        throwsA(isA<SceneException>()),
      );
    },
  );
  test(
    'frame graph initializes scene color and retains its terminal output',
    () async {
      final graph = await compiler.compile(description());
      expect(graph.isFrameGraph, isTrue);
      expect(device.submitted!.data['sceneColor'], isNotNull);
      expect(device.submitted!.data['output'], isNotNull);
      expect(
        graph.lifetimes.firstWhere((e) => e.resourceLabel == 'scene').firstPass,
        -1,
      );
      expect(
        graph.lifetimes.firstWhere((e) => e.resourceLabel == 'output').lastPass,
        1,
      );
      await expectLater(graph.execute(), throwsA(isA<GraphException>()));
      var called = false;
      await graph.submitFrame(device, PhysicalSize(17, 13), (key) async {
        called = true;
      });
      expect(called, isTrue);
    },
  );
  test(
    'frame graph rejects partial contracts, missing usage and discarded output',
    () async {
      for (final candidate in [
        GraphDescription(sceneColor: scene, passes: description().passes),
        GraphDescription(output: output, passes: description().passes),
        description(discard: true),
      ]) {
        await expectLater(
          compiler.compile(candidate),
          throwsA(isA<GraphException>()),
        );
      }
      final invalid = await resources.createTexture(
        TextureDescriptor(width: 17, height: 13),
      );
      await expectLater(
        compiler.compile(
          GraphDescription(
            sceneColor: invalid,
            output: output,
            passes: description().passes,
          ),
        ),
        throwsA(isA<GraphException>()),
      );
      expect(device.graphs, isEmpty);
    },
  );
  test(
    'frame submit rejects foreign devices and size mismatch without calling adapter',
    () async {
      final graph = await compiler.compile(description());
      Future<void> unexpected(Object key) async =>
          fail('adapter must not be called');
      await expectLater(
        graph.submitFrame(Device(), PhysicalSize(17, 13), unexpected),
        throwsA(isA<GraphException>()),
      );
      await expectLater(
        graph.submitFrame(device, PhysicalSize(18, 13), unexpected),
        throwsA(isA<GraphException>()),
      );
    },
  );
  test(
    'reentrant adapter close cannot release a submitted graph early',
    () async {
      final graph = await compiler.compile(description());
      final gate = Completer<void>();
      Future<void>? closing;
      final work = graph.submitFrame(device, PhysicalSize(17, 13), (_) {
        closing = graph.close();
        return gate.future;
      });
      await Future<void>.delayed(Duration.zero);
      final retained = device.graphs.isNotEmpty;
      gate.complete();
      await work;
      await closing;
      expect(retained, isTrue);
    },
  );
  test(
    'frame submit drains on close and survives closed author scopes',
    () async {
      final graph = await compiler.compile(description());
      await resources.close();
      await shaders.close();
      final gate = Completer<void>();
      final work = graph.submitFrame(
        device,
        PhysicalSize(17, 13),
        (key) => gate.future,
      );
      final closing = graph.close();
      expect(device.graphs, isNotEmpty);
      await expectLater(
        graph.submitFrame(device, PhysicalSize(17, 13), (_) async {}),
        throwsStateError,
      );
      gate.complete();
      await work;
      await closing;
      expect(device.graphs, isEmpty);
    },
  );
}

class FrameBackend implements RenderBackend {
  final bool supported;
  FrameBackend({this.supported = true});
  FrameSubmission? last;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'frame test',
    features: {if (supported) RenderFeature.frameGraphs},
    limits: DeviceLimits(maxTextureDimension2D: 4096, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    last = submission;
    return ReadbackOutput(
      image: ImageData(
        pixels: Uint8List(submission.size.width * submission.size.height * 4),
        size: submission.size,
      ),
      stats: FrameStats(
        frameId: 1,
        physicalSize: submission.size,
        presentationPath: PresentationPath.readback,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: 0,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {}
}

class FramePlugin extends ScenePlugin {
  @override
  final String id;
  final CompiledGraph compiled;
  late PluginContext context;
  late FrameGraphBinding binding;
  FramePlugin(this.id, this.compiled);
  @override
  void attach(PluginContext context) {
    this.context = context;
    binding = context.frameGraph;
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    binding.graph = compiled;
  }
}
