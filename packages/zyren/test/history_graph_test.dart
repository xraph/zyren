import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'shared_graph_test.dart' show SharedBackend, SharedDevice;

class HistoryDevice extends SharedDevice {
  final descriptions = <GraphDeviceDescription>[];
  final historyWrites = <List<int>>[];
  int? rejectBuild;
  Completer<void>? writing, writeGate;
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async {
    final key = Object();
    authors.add(key);
    return key;
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes) async {
    if (!(writing?.isCompleted ?? true)) writing!.complete();
    await writeGate?.future;
    historyWrites.add([
      for (var i = 0; i < 4; i++)
        ByteData.sublistView(bytes).getUint32(i * 4, Endian.little),
    ]);
  }

  @override
  Future<Object> compileGraph(GraphDeviceDescription description) {
    descriptions.add(description);
    reject = descriptions.length == rejectBuild;
    return super.compileGraph(description);
  }
}

class HistoryBackend extends SharedBackend {
  final _historyDevice = HistoryDevice();
  @override
  HistoryDevice get device => _historyDevice;
  bool fail = false;
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final result = await super.render(submission);
    if (fail) throw StateError('frame rejected');
    return result;
  }
}

class HistoryPlugin extends ScenePlugin {
  @override
  String get id => 'history';
  late PluginContext context;
  late GraphRegistration registration;
  bool alias = false;
  String? invalid;
  Completer<void>? building, proceed;
  @override
  Future<void> attach(PluginContext context) async {
    this.context = context;
    final shader = await context.shaders.compile(ShaderSource.wgsl('valid'));
    registration = context.graph.addEffect(
      name: id,
      build: (frame) async {
        final history = await frame.createHistory(label: 'trail');
        final previous = alias
            ? await frame.resources.retain(history.previous)
            : history.previous;
        if (!(building?.isCompleted ?? true)) building!.complete();
        await proceed?.future;
        return GraphEffect(
          output: history.current,
          inputs: invalid == 'import' ? [history.current] : [],
          passes: [
            RenderPassDescriptor(
              name: 'accumulate',
              program: shader,
              color: ColorAttachment(
                invalid == 'previous' ? previous : history.current,
                store: invalid == 'discard'
                    ? AttachmentStore.discard
                    : AttachmentStore.store,
              ),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, frame.input),
                TextureBinding.sampled(1, previous),
                BufferBinding.uniform(2, history.uniforms),
              ]),
              reads: [frame.input, previous, history.uniforms],
              writes: [invalid == 'previous' ? previous : history.current],
            ),
          ],
        );
      },
    );
  }
}

void main() {
  late HistoryBackend backend;
  late HistoryPlugin plugin;
  late SceneEngine engine;
  final issues = <SceneIssue>[];
  setUp(() async {
    backend = HistoryBackend();
    plugin = HistoryPlugin();
    issues.clear();
    engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: [plugin],
      onIssue: issues.add,
    );
  });
  tearDown(() => engine.dispose());
  Future<FrameOutput> draw([int width = 17]) =>
      engine.renderFrame(elapsed: Duration.zero, width: width, height: 13);
  test(
    'precision changes reset history while exposure edits preserve it',
    () async {
      await draw();
      await engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(),
      );
      expect(backend.device.historyWrites.last[0], 0);
      final builds = backend.device.builds;
      await engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
        colorPipeline: ColorPipeline(exposure: .25),
      );
      expect(backend.device.historyWrites.last[0], 1);
      expect(backend.device.builds, builds);
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
    },
  );
  for (final invalid in ['previous', 'discard', 'import']) {
    test(
      'invalid history $invalid fails before compiling and releases candidates',
      () async {
        plugin.invalid = invalid;
        await expectLater(draw(), throwsA(isA<GraphException>()));
        expect(backend.device.builds, 0);
        expect(backend.device.authors, isEmpty);
      },
    );
  }
  test(
    'reset during metadata upload defers the frame and retries cleanly',
    () async {
      await draw();
      final last = backend.last;
      backend.device.writing = Completer<void>();
      backend.device.writeGate = Completer<void>();
      final frame = draw();
      await backend.device.writing!.future;
      engine.invalidateHistory();
      final failed = expectLater(
        frame,
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.frameDeferred,
          ),
        ),
      );
      backend.device.writeGate!.complete();
      await failed;
      expect(backend.last, same(last));
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
    },
  );
  test('failed initial second variant cleans every candidate owner', () async {
    backend.device.rejectBuild = 2;
    await expectLater(draw(), throwsA(isA<GraphException>()));
    expect(backend.device.graphs, isEmpty);
    expect(backend.device.authors, isEmpty);
    plugin.registration.invalidate();
    await draw();
    expect(plugin.context.graph.state.historyFrames, 1);
  });
  test(
    'failed resize cannot submit old dimensions or advance history',
    () async {
      await draw();
      final previous = backend.last;
      backend.device.rejectBuild = 4;
      await expectLater(draw(23), throwsA(isA<GraphException>()));
      expect(backend.last, same(previous));
      expect(plugin.context.graph.state.historyFrames, 1);
      await draw();
      expect(backend.device.historyWrites.last[0], 1);
    },
  );
  test(
    'closing during a history build drains candidate textures and variants',
    () async {
      plugin.building = Completer<void>();
      plugin.proceed = Completer<void>();
      final frame = draw();
      await plugin.building!.future;
      final failed = expectLater(frame, throwsStateError);
      final closing = engine.dispose();
      plugin.proceed!.complete();
      await failed;
      await closing;
      expect(backend.device.graphs, isEmpty);
      expect(backend.device.authors, isEmpty);
    },
  );
  test(
    'history swaps only after successful frames without recompilation',
    () async {
      await draw();
      final first = backend.last!.graph;
      expect(backend.device.builds, 2);
      expect(backend.device.historyWrites.last[0], 0);
      expect(plugin.context.graph.state.historyFrames, 1);
      await draw();
      final second = backend.last!.graph;
      expect(second, isNot(same(first)));
      expect(backend.device.historyWrites.last[0], 1);
      backend.fail = true;
      await expectLater(draw(), throwsStateError);
      expect(backend.last!.graph, same(first));
      expect(plugin.context.graph.state.historyFrames, 2);
      backend.fail = false;
      await draw();
      expect(backend.last!.graph, same(first));
      expect(backend.device.historyWrites.last[0], 2);
      expect(backend.device.builds, 2);
    },
  );
  test(
    'camera motion preserves history; cuts and projection edits reset it',
    () async {
      await draw();
      engine.camera.position = const Vec3(1, 0, 5);
      await draw();
      expect(backend.device.historyWrites.last[0], 1);
      (engine.camera as PerspectiveCamera).fieldOfView = .7;
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
      final generation = backend.device.historyWrites.last[1];
      plugin.context.graph.invalidateHistory();
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
      expect(backend.device.historyWrites.last[1], greaterThan(generation));
      engine.camera = PerspectiveCamera(fieldOfView: .7);
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
      expect(backend.device.builds, 2);
    },
  );
  test('resize replaces both variants and starts fresh history', () async {
    await draw();
    final first = backend.last!.graph!;
    await draw(23);
    expect(first.isClosed, isTrue);
    expect(backend.device.graphs, hasLength(2));
    expect(backend.device.historyWrites.last[0], 0);
    expect(backend.device.builds, 4);
  });
  test(
    'second variant failure preserves active history and cleans candidates',
    () async {
      await draw();
      final authors = backend.device.authors.length;
      backend.device.rejectBuild = 4;
      plugin.registration.invalidate();
      await draw();
      expect(issues, hasLength(1));
      expect(backend.device.graphs, hasLength(2));
      expect(backend.device.authors, hasLength(authors));
      expect(backend.device.historyWrites.last[0], 1);
      await draw();
      expect(backend.device.builds, 4);
      expect(backend.device.historyWrites.last[0], 2);
    },
  );
  test(
    'reset during a submitted frame cannot advance the new history epoch',
    () async {
      await draw();
      backend.frameGate = Completer<void>();
      backend.frameEntered = Completer<void>();
      final frame = draw();
      await backend.frameEntered!.future;
      engine.invalidateHistory();
      backend.frameGate!.complete();
      await frame;
      expect(plugin.context.graph.state.historyFrames, 0);
      await draw();
      expect(backend.device.historyWrites.last[0], 0);
    },
  );
  test(
    'retained history aliases swap in bindings and access declarations',
    () async {
      plugin.alias = true;
      await draw();
      final a =
          (backend.device.descriptions[0].data['passes'] as List).single as Map;
      final b =
          (backend.device.descriptions[1].data['passes'] as List).single as Map;
      final readsA = a['reads'] as List, readsB = b['reads'] as List;
      expect(readsB[1], (a['writes'] as List).single);
      expect((b['writes'] as List).single, readsA[1]);
      expect(((b['bindings'] as List)[1] as Map)['key'], readsB[1]);
    },
  );
  test(
    'candidate camera capture stays frozen while the effect awaits',
    () async {
      plugin.building = Completer<void>();
      plugin.proceed = Completer<void>();
      final frame = draw();
      await plugin.building!.future;
      engine.camera.position = const Vec3(9, 0, 5);
      (engine.camera as PerspectiveCamera).fieldOfView = .7;
      plugin.proceed!.complete();
      await frame;
      expect(backend.last!.camera.origin, [0, 0, 5]);
      await draw();
      expect(backend.last!.camera.origin, [9, 0, 5]);
      expect(backend.device.historyWrites.last[0], 0);
    },
  );
}
