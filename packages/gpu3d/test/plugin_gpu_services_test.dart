import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class _Device implements GraphDevice {
  final resources = <Object>{}, shaders = <Object>{}, graphs = <Object>{};
  Completer<void>? compilation;
  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async {
    final key = Object();
    resources.add(key);
    return key;
  }

  @override
  Future<void> release(Object key) async => resources.remove(key);
  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final key = Object();
    shaders.add(key);
    return ShaderBuild(
      key: key,
      entryPoints: const [
        ShaderEntryPoint(name: 'main', stage: ShaderStage.compute),
      ],
    );
  }

  @override
  Future<void> releaseShader(Object key) async => shaders.remove(key);
  @override
  Future<Object> compileGraph(GraphDeviceDescription description) async {
    await compilation?.future;
    final key = Object();
    graphs.add(key);
    return key;
  }

  @override
  Future<void> releaseGraph(Object key) async => graphs.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend implements GraphBackend {
  final device = _Device();
  final resources = <ResourceScope>[];
  final graphs = <GraphCompiler>[];
  final shaders = <ShaderCompiler>[];
  bool closed = false;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'plugin services',
    features: {
      RenderFeature.scopedResources,
      RenderFeature.shaderCompilation,
      RenderFeature.renderGraphs,
    },
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  ResourceScope createResourceScope({String label = ''}) {
    final scope = ResourceScope(device, label: label);
    resources.add(scope);
    return scope;
  }

  @override
  ShaderCompiler createShaderCompiler({String label = ''}) {
    final compiler = ShaderCompiler(device, label: label);
    shaders.add(compiler);
    return compiler;
  }

  @override
  GraphCompiler createGraphCompiler({String label = ''}) {
    final compiler = GraphCompiler(device, label: label);
    graphs.add(compiler);
    return compiler;
  }

  @override
  Future<FrameOutput> render(FrameSubmission submission) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    // Deliberately does not clean up scopes. Plugin attachments must own them.
    expect(device.resources, isEmpty);
    expect(device.shaders, isEmpty);
    expect(device.graphs, isEmpty);
    closed = true;
  }
}

Future<GraphDescription> _description(PluginContext context) async {
  final texture = await context.resources.createTexture(
    TextureDescriptor(
      width: 8,
      height: 8,
      format: TextureFormat.rgba8Unorm,
      usage: {TextureUsage.storage},
    ),
  );
  final program = await context.shaders.compile(ShaderSource.wgsl('valid'));
  return GraphDescription(
    passes: [
      ComputePassDescriptor(
        name: 'update',
        program: program,
        workgroups: const Workgroups(1),
        bindings: ShaderBindings([TextureBinding.storage(0, texture)]),
        writes: [texture],
      ),
    ],
  );
}

void main() {
  test(
    'GPU services are lazy, stable and isolated per plugin attachment',
    () async {
      final backend = _Backend();
      final contexts = <PluginContext>[];
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          for (final name in ['first', 'second'])
            TestPlugin(
              name,
              [],
              onAttach: (context) async {
                contexts.add(context);
                // Creating graphs first also exercises reverse cleanup ordering.
                final compiler = context.graphs;
                expect(context.graphs, same(compiler));
                expect(compiler.label, name);
                final description = await _description(context);
                expect(context.resources, same(backend.resources.last));
                expect(context.resources.label, name);
                await compiler.compile(description);
              },
              onDetach: (context) {
                expect(() => context.resources, throwsStateError);
                expect(() => context.graphs, throwsStateError);
              },
            ),
          TestPlugin('unused', []),
        ],
      );
      expect(backend.resources.length, 2);
      expect(backend.graphs.length, 2);
      expect(contexts[0].resources, isNot(same(contexts[1].resources)));
      contexts.first.scope.close();
      await contexts.first.scope.whenClosed;
      expect(backend.resources.first.isClosed, isTrue);
      expect(backend.graphs.first.isClosed, isTrue);
      expect(contexts.last.resources.isClosed, isFalse);
      expect(contexts.last.graphs.active!.isClosed, isFalse);
      await engine.dispose();
      expect(backend.closed, isTrue);
    },
  );

  test(
    'cancelled attachment drains a pending graph before backend close',
    () async {
      final backend = _Backend();
      backend.device.compilation = Completer<void>();
      final lifetime = AttachmentScope(), attaching = Completer<void>();
      final engine = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        lifetime: lifetime,
        plugins: [
          TestPlugin(
            'pending',
            [],
            onAttach: (context) async {
              final description = await _description(context);
              final pending = context.graphs.compile(description);
              attaching.complete();
              await pending;
            },
          ),
        ],
      );
      final outcome = expectLater(engine, throwsA(isA<SceneException>()));
      await attaching.future;
      lifetime.close();
      expect(backend.graphs.single.isClosed, isTrue);
      expect(backend.resources.single.isClosed, isTrue);
      expect(backend.closed, isFalse);
      backend.device.compilation!.complete();
      await outcome;
      expect(backend.closed, isTrue);
    },
  );

  test('failed attachment releases its compiled graph and resources', () async {
    final backend = _Backend();
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          TestPlugin(
            'failed',
            [],
            onAttach: (context) async {
              await context.graphs.compile(await _description(context));
              throw StateError('attachment failed');
            },
          ),
        ],
      ),
      throwsStateError,
    );
    expect(backend.closed, isTrue);
  });

  for (final feature in [
    RenderFeature.scopedResources,
    RenderFeature.renderGraphs,
  ]) {
    test(
      'unsupported ${feature.name} identifies the requesting plugin',
      () async {
        await expectLater(
          SceneEngine.create(
            scene: Scene(),
            camera: PerspectiveCamera(),
            rendererFactory: () async => TestRenderer([]),
            plugins: [
              TestPlugin(
                'weather',
                [],
                onAttach: (context) {
                  if (feature == RenderFeature.scopedResources) {
                    context.resources;
                  } else {
                    context.graphs;
                  }
                },
              ),
            ],
          ),
          throwsA(
            isA<SceneException>()
                .having((e) => e.issue.pluginId, 'plugin', 'weather')
                .having((e) => e.issue.requiredFeatures, 'features', {feature})
                .having(
                  (e) => e.issue.code,
                  'code',
                  SceneIssueCodes.unsupportedFeature,
                ),
          ),
        );
      },
    );
  }
}
