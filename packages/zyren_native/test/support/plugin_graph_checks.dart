import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

const _output = ServiceKey<GpuResource<Texture>>('test.graph.output');

class _Provider extends ScenePlugin {
  @override
  String get id => 'test.graph.provider';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.compute,
    RenderFeature.storageTextures,
  };
  late CompiledGraph graph;
  final bool fail;
  _Provider({this.fail = false});

  @override
  Future<void> attach(PluginContext context) async {
    final texture = await context.resources.createTexture(
      TextureDescriptor(
        label: 'plugin output',
        width: 8,
        height: 8,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.copySource},
      ),
    );
    final shader = await context.shaders.compile(
      ShaderSource.wgsl('''
      @group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
      @compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
        textureStore(output, vec2<i32>(id.xy), vec4<f32>(0., 1., 0., 1.));
      }
    ''', label: 'plugin.wgsl'),
    );
    graph = await context.graphs.compile(
      GraphDescription(
        passes: [
          ComputePassDescriptor(
            name: 'plugin.compute',
            program: shader,
            workgroups: const Workgroups(1),
            bindings: ShaderBindings([TextureBinding.storage(0, texture)]),
            writes: [texture],
          ),
        ],
      ),
    );
    context.provide(_output, texture);
    if (fail) throw StateError('provider attach failed');
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    await graph.execute();
  }
}

class _Consumer extends ScenePlugin {
  @override
  String get id => 'test.graph.consumer';
  @override
  Set<String> get dependencies => {'test.graph.provider'};
  @override
  Set<RenderFeature> get requiredFeatures => {RenderFeature.scopedResources};
  late GpuResource<Texture> texture;
  int frames = 0;
  @override
  Future<void> attach(PluginContext context) async {
    texture = await context.resources.retain(context.service(_output));
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    expect(await context.resources.readTexture(texture), [
      for (var i = 0; i < 64; i++) ...[0, 255, 0, 255],
    ]);
    frames++;
  }
}

Future<void> verifyPluginGraphs() async {
  final backend = await NativeBackend.create();
  final observer = backend.createView();
  SceneEngine? first, second;
  final firstProvider = _Provider(), secondProvider = _Provider();
  final firstConsumer = _Consumer(), secondConsumer = _Consumer();
  try {
    first = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: [firstConsumer, firstProvider],
    );
    second = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => observer.createView(),
      plugins: [secondConsumer, secondProvider],
    );
    await first.renderFrame(elapsed: Duration.zero, width: 8, height: 8);
    await second.renderFrame(elapsed: Duration.zero, width: 8, height: 8);
    expect((await observer.graphStats()).liveGraphs, 2);
    expect((await observer.graphStats()).cachedPipelines, 1);
    expect(firstConsumer.frames, 1);
    await first.dispose();
    expect(firstProvider.graph.isClosed, isTrue);
    expect(firstConsumer.texture.isClosed, isTrue);
    expect((await observer.graphStats()).liveGraphs, 1);
    await second.renderFrame(
      elapsed: const Duration(milliseconds: 16),
      width: 8,
      height: 8,
    );
    expect(secondConsumer.frames, 2);
    await second.dispose();
    expect((await observer.graphStats()).liveGraphs, 0);
    expect((await observer.graphStats()).cachedPipelines, 0);
    expect((await observer.resourceStats()).residentBytes, 0);
    expect((await observer.shaderStats()).livePrograms, 0);
    expect((await observer.shaderStats()).cachedModules, 0);

    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => observer.createView(),
        plugins: [_Provider(fail: true)],
      ),
      throwsStateError,
    );
    expect((await observer.graphStats()).liveGraphs, 0);
    expect((await observer.graphStats()).cachedPipelines, 0);
    expect((await observer.resourceStats()).residentBytes, 0);
    expect((await observer.shaderStats()).cachedModules, 0);
  } finally {
    await first?.dispose();
    await second?.dispose();
    await backend.close();
    await observer.close();
  }
}
