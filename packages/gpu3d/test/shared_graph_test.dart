import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'frame_graph_test.dart' show FrameBackend;
import 'render_graph_test.dart' show Device;
import 'support/fakes.dart' show TestPlugin;

class SharedDevice extends Device {
  final authors = <Object>{};
  int builds = 0;
  Completer<void>? entered;
  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async {
    final key = Object();
    authors.add(key);
    return key;
  }

  @override
  Future<void> release(Object key) async => authors.remove(key);
  @override
  Future<Object> compileGraph(GraphDeviceDescription description) {
    builds++;
    if (!(entered?.isCompleted ?? true)) entered!.complete();
    return super.compileGraph(description);
  }
}

class SharedBackend extends FrameBackend implements GraphBackend {
  final device = SharedDevice();
  Completer<void>? frameGate, frameEntered;
  bool closed = false;
  Set<RenderFeature> features = RenderFeature.values.toSet();
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'shared fixture',
    features: features,
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      ResourceScope(device, label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      ShaderCompiler(device, label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      GraphCompiler(device, label: label);
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    last = submission;
    if (!(frameEntered?.isCompleted ?? true)) frameEntered!.complete();
    await frameGate?.future;
    return super.render(submission);
  }

  @override
  Future<void> close() async {
    expect(device.authors, isEmpty);
    expect(device.graphs, isEmpty);
    closed = true;
  }
}

class EffectPlugin extends ScenePlugin {
  @override
  final String id;
  final Set<String> after;
  late PluginContext context;
  late GraphRegistration registration;
  ShaderProgram? program;
  final formats = <TextureFormat>[];
  TextureFormat? outputFormat;
  bool failBuild = false;
  Completer<void>? buildGate;
  Completer<void>? buildEntered;
  EffectPlugin(this.id, {this.after = const {}});
  @override
  Future<void> attach(PluginContext context) async {
    this.context = context;
    program = await context.shaders.compile(ShaderSource.wgsl('valid'));
    registration = context.graph.addEffect(
      name: id,
      after: after,
      build: (frame) async {
        formats.add((frame.input.descriptor as TextureDescriptor).format);
        final output = await frame.createColorTexture(
          label: '$id output',
          format: outputFormat,
        );
        if (!(buildEntered?.isCompleted ?? true)) buildEntered!.complete();
        await buildGate?.future;
        if (failBuild) throw StateError('broken effect');
        return GraphEffect(
          output: output,
          passes: [
            RenderPassDescriptor(
              name: '$id pass',
              program: program!,
              color: ColorAttachment(output),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, frame.input),
              ]),
              reads: [frame.input],
              writes: [output],
            ),
          ],
        );
      },
    );
  }
}

void main() {
  late SharedBackend backend;
  late SceneEngine engine;
  final issues = <SceneIssue>[];
  var invalidations = 0;
  setUp(() {
    backend = SharedBackend();
    issues.clear();
    invalidations = 0;
  });
  Future<void> start(List<ScenePlugin> plugins) async {
    engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: plugins,
      onInvalidate: () {
        invalidations++;
      },
      onIssue: issues.add,
    );
    addTearDown(engine.dispose);
  }

  Future<FrameOutput> draw([int width = 17]) =>
      engine.renderFrame(elapsed: Duration.zero, width: width, height: 13);

  test(
    'shared effects inherit HDR and rebuild only when precision changes',
    () async {
      final effect = EffectPlugin('precision');
      await start([effect]);
      await engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(),
      );
      final hdr = backend.last!.graph;
      await engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(exposure: .2),
      );
      expect(backend.last!.graph, same(hdr));
      expect(effect.formats, [TextureFormat.rgba16Float]);
      await draw();
      expect(effect.formats, [
        TextureFormat.rgba16Float,
        TextureFormat.rgba8UnormSrgb,
      ]);
      expect(backend.last!.graph, isNot(same(hdr)));
      effect.failBuild = true;
      await expectLater(
        engine.renderFrame(
          elapsed: Duration.zero,
          width: 17,
          height: 13,
          colorPipeline: ColorPipeline(),
        ),
        throwsA(isA<SceneException>()),
      );
      expect(effect.context.graph.state.issue, isNotNull);
      effect.failBuild = false;
      effect.registration.invalidate();
      await engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(exposure: .5),
      );
      expect(backend.last!.colorPipeline?.exposure, .5);
    },
  );

  test('an HDR effect cannot silently narrow the shared color chain', () async {
    final effect = EffectPlugin('narrow')
      ..outputFormat = TextureFormat.rgba8Unorm;
    await start([effect]);
    await expectLater(
      engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(),
      ),
      throwsA(isA<GraphException>()),
    );
    expect(backend.last, isNull);
    expect(backend.device.authors, isEmpty);
  });

  test(
    'independent effects chain in dependency order and reuse until resize',
    () async {
      final color = EffectPlugin('color'),
          vignette = EffectPlugin('vignette', after: {'color'});
      await start([vignette, color]);
      await draw();
      final graph = backend.last!.graph!;
      expect(graph.passNames, ['color pass', 'vignette pass']);
      final data = backend.device.submitted!.data;
      final passes = (data['passes'] as List).cast<Map>();
      expect(
        passes.last['reads'],
        contains((passes.first['writes'] as List).single),
      );
      expect(backend.device.authors, isEmpty);
      await draw();
      expect(backend.last!.graph, same(graph));
      expect(backend.device.builds, 1);
      await draw(23);
      expect(graph.isClosed, isTrue);
      expect(color.context.graph.state.size!.width, 23);
      expect(color.context.graph.state.builds, 2);
      expect(backend.device.graphs, hasLength(1));
    },
  );
  test(
    'disable bypasses an effect and disposal removes its registration',
    () async {
      final a = EffectPlugin('a'), b = EffectPlugin('b', after: {'a'});
      await start([a, b]);
      await draw();
      a.registration.enabled = false;
      expect(invalidations, greaterThan(0));
      await draw();
      expect(backend.last!.graph!.passNames, ['b pass']);
      a.registration.enabled = true;
      b.registration.dispose();
      b.registration.dispose();
      await draw();
      expect(backend.last!.graph!.passNames, ['a pass']);
      a.registration.dispose();
      await draw();
      expect(backend.last!.graph, isNull);
      expect(backend.device.graphs, isEmpty);
      expect(() => a.registration.enabled = true, throwsStateError);
    },
  );
  test(
    'failed edit keeps the active graph and reports once until invalidated',
    () async {
      final effect = EffectPlugin('color');
      await start([effect]);
      await draw();
      final previous = backend.last!.graph;
      effect.failBuild = true;
      effect.registration.invalidate();
      await draw();
      expect(backend.last!.graph, same(previous));
      expect(previous!.isClosed, isFalse);
      expect(issues.single.pluginId, 'color');
      expect(effect.context.graph.state.issue, same(issues.single));
      await draw();
      expect(issues, hasLength(1));
      expect(backend.device.authors, isEmpty);
      effect.failBuild = false;
      effect.registration.invalidate();
      await draw();
      expect(previous.isClosed, isTrue);
      expect(effect.context.graph.state.issue, isNull);
    },
  );
  test(
    'failed resize preserves the old size and allows a subsequent rebuild',
    () async {
      final effect = EffectPlugin('color');
      await start([effect]);
      await draw();
      final previous = backend.last!.graph!;
      backend.device.reject = true;
      await expectLater(draw(23), throwsA(isA<GraphException>()));
      expect(previous.isClosed, isFalse);
      await draw();
      expect(backend.last!.graph, same(previous));
      backend.device.reject = false;
      effect.registration.invalidate();
      await draw(23);
      expect(previous.isClosed, isTrue);
    },
  );
  test(
    'registration mutation during compilation discards the stale candidate',
    () async {
      final effect = EffectPlugin('color');
      await start([effect]);
      await draw();
      final previous = backend.last!.graph!;
      backend.device.gate = Completer<void>();
      backend.device.entered = Completer<void>();
      effect.registration.invalidate();
      final pending = expectLater(
        draw(),
        throwsA(
          isA<SceneException>().having(
            (error) => error.issue.code,
            'code',
            SceneIssueCodes.frameDeferred,
          ),
        ),
      );
      await backend.device.entered!.future;
      effect.registration.enabled = false;
      backend.device.gate!.complete();
      await pending;
      expect(previous.isClosed, isFalse);
      expect(backend.device.graphs, hasLength(1));
      expect(backend.device.authors, isEmpty);
      await draw();
      expect(backend.last!.graph, isNull);
      expect(previous.isClosed, isTrue);
    },
  );
  test(
    'dispose during effect build drains temporary owners without submitting',
    () async {
      final effect = EffectPlugin('color')
        ..buildGate = Completer<void>()
        ..buildEntered = Completer<void>();
      await start([effect]);
      final pending = expectLater(draw(), throwsStateError);
      await effect.buildEntered!.future;
      final closing = engine.dispose();
      expect(backend.closed, isFalse);
      effect.buildGate!.complete();
      await pending;
      await closing;
      expect(backend.last, isNull);
      expect(backend.closed, isTrue);
      expect(effect.registration.isDisposed, isTrue);
    },
  );
  test('fixed preparation passes share the graph with effects', () async {
    await start([
      TestPlugin(
        'preparation',
        [],
        onAttach: (context) async {
          final resource = await context.resources.createTexture(
            TextureDescriptor(
              width: 2,
              height: 2,
              format: TextureFormat.rgba8Unorm,
              usage: {TextureUsage.storage},
            ),
          );
          final program = await context.shaders.compile(
            ShaderSource.wgsl('valid'),
          );
          context.graph.addCompute(
            ComputePassDescriptor(
              name: 'prepare',
              program: program,
              workgroups: const Workgroups(1),
              writes: [resource],
              bindings: ShaderBindings([TextureBinding.storage(0, resource)]),
            ),
          );
        },
      ),
      EffectPlugin('color'),
    ]);
    await draw();
    expect(backend.last!.graph!.passNames, ['prepare', 'color pass']);
    expect(backend.last!.graph!.beforeScenePassCount, 1);
  });
  test(
    'late registration and mixing manual and shared composition are rejected',
    () async {
      final effect = EffectPlugin('color');
      await start([effect]);
      expect(
        () => effect.context.graph.addEffect(
          name: 'late',
          build: (_) => throw UnimplementedError(),
        ),
        throwsStateError,
      );
      expect(() => effect.context.frameGraph, throwsStateError);
      await draw();
      await expectLater(
        engine.renderFrame(
          graph: backend.last!.graph,
          elapsed: Duration.zero,
          width: 17,
          height: 13,
        ),
        throwsStateError,
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => SharedBackend(),
          plugins: [
            TestPlugin(
              'manual',
              [],
              onAttach: (c) {
                c.frameGraph;
              },
            ),
            EffectPlugin('shared'),
          ],
        ),
        throwsStateError,
      );
    },
  );
  test(
    'effect cycles and missing capabilities fail with labeled errors',
    () async {
      await start([
        EffectPlugin('a', after: {'b'}),
        EffectPlugin('b', after: {'a'}),
      ]);
      await expectLater(
        draw(),
        throwsA(
          isA<GraphException>().having(
            (e) => e.code,
            'code',
            GraphErrorCode.cycle,
          ),
        ),
      );
      expect(backend.device.authors, isEmpty);
      final unsupported = SharedBackend()
        ..features.remove(RenderFeature.frameGraphs);
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => unsupported,
          plugins: [EffectPlugin('weather')],
        ),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.pluginId,
            'plugin',
            'weather',
          ),
        ),
      );
    },
  );
  test(
    'closing one attachment removes its contribution without retiring another',
    () async {
      final a = EffectPlugin('a'), b = EffectPlugin('b');
      await start([a, b]);
      await draw();
      a.context.scope.close();
      await a.context.scope.whenClosed;
      await draw();
      expect(backend.last!.graph!.passNames, ['b pass']);
      expect(a.registration.isDisposed, isTrue);
      expect(b.registration.isDisposed, isFalse);
      expect(() => a.context.graph, throwsStateError);
      expect(backend.device.graphs, hasLength(1));
    },
  );
  test(
    'a no-op effect leaves direct scene presentation and releases its candidate',
    () async {
      await start([
        TestPlugin(
          'bypass',
          [],
          onAttach: (context) {
            context.graph.addEffect(
              name: 'bypass',
              build: (frame) => GraphEffect(output: frame.input, passes: []),
            );
          },
        ),
      ]);
      await draw();
      expect(backend.last!.graph, isNull);
      expect(backend.device.authors, isEmpty);
      expect(backend.device.builds, 0);
    },
  );
  test('failed attachment rolls back already registered effects', () async {
    final effect = EffectPlugin('color');
    await expectLater(
      start([
        effect,
        TestPlugin(
          'broken',
          [],
          onAttach: (_) {
            throw StateError('attach');
          },
        ),
      ]),
      throwsStateError,
    );
    expect(effect.registration.isDisposed, isTrue);
    expect(backend.closed, isTrue);
    expect(backend.device.graphs, isEmpty);
  });
  test(
    'disposal drains an accepted frame before releasing shared graph ownership',
    () async {
      final effect = EffectPlugin('color');
      await start([effect]);
      await draw();
      backend.frameGate = Completer<void>();
      backend.frameEntered = Completer<void>();
      final frame = draw();
      await backend.frameEntered!.future;
      final active = backend.last!.graph!;
      final closing = engine.dispose();
      expect(active.isClosed, isFalse);
      expect(backend.closed, isFalse);
      backend.frameGate!.complete();
      await frame;
      await closing;
      expect(active.isClosed, isTrue);
      expect(backend.closed, isTrue);
    },
  );
}
