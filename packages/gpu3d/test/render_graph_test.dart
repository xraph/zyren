import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

class Device implements GraphDevice {
  GraphDeviceDescription? submitted;
  bool reject = false;
  Object? releaseFailure;
  Completer<void>? gate;
  Completer<void>? executionGate;
  final graphs = <Object>{};
  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async => Object();
  @override
  Future<void> retain(Object key) async {}
  @override
  Future<void> release(Object key) async {}
  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async => ShaderBuild(
    key: Object(),
    entryPoints: const [
      ShaderEntryPoint(
        name: 'main',
        stage: ShaderStage.compute,
        workgroupSize: (8, 8, 1),
      ),
      ShaderEntryPoint(name: 'vertex', stage: ShaderStage.vertex),
      ShaderEntryPoint(name: 'fragment', stage: ShaderStage.fragment),
    ],
  );
  @override
  Future<void> releaseShader(Object key) async {}
  @override
  Future<Object> compileGraph(GraphDeviceDescription description) async {
    submitted = description;
    await gate?.future;
    if (reject) {
      throw GraphException(
        GraphErrorCode.pipelineFailed,
        'WGSL layout mismatch',
        passName: 'sample',
      );
    }
    final key = Object();
    graphs.add(key);
    return key;
  }

  @override
  Future<GraphStats> executeGraph(Object key) async {
    await executionGate?.future;
    return const GraphStats(passes: 2, dispatches: 1, drawCalls: 1);
  }

  @override
  Future<void> releaseGraph(Object key) async {
    graphs.remove(key);
    if (releaseFailure != null) throw releaseFailure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Device device;
  late ResourceScope scope;
  late ShaderCompiler shaders;
  late GraphCompiler compiler;
  late ShaderProgram program;
  late GpuResource<Texture> source, output;
  setUp(() async {
    device = Device();
    scope = ResourceScope(device);
    shaders = ShaderCompiler(device);
    compiler = GraphCompiler(device);
    program = await shaders.compile(ShaderSource.wgsl('valid'));
    source = await scope.createTexture(
      TextureDescriptor(
        label: 'density',
        width: 64,
        height: 64,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      ),
    );
    output = await scope.createTexture(
      TextureDescriptor(
        label: 'color',
        width: 64,
        height: 64,
        usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
      ),
    );
  });
  tearDown(() async {
    if (device.gate != null && !device.gate!.isCompleted) {
      device.gate!.complete();
    }
    if (device.executionGate != null && !device.executionGate!.isCompleted) {
      device.executionGate!.complete();
    }
    await compiler.close();
    await shaders.close();
    await scope.close();
  });
  test(
    'close while replacement retires an executing graph never publishes the candidate',
    () async {
      final description = GraphDescription(
        passes: [
          ComputePassDescriptor(
            name: 'work',
            program: program,
            workgroups: const Workgroups(1),
            bindings: ShaderBindings([TextureBinding.storage(0, source)]),
            writes: [source],
          ),
        ],
      );
      final old = await compiler.compile(description);
      device.executionGate = Completer<void>();
      final execution = old.execute();
      final pending = compiler.compile(description);
      await Future<void>.delayed(Duration.zero);
      final outcome = expectLater(pending, throwsStateError);
      final closing = compiler.close();
      final stopped = compiler.active!.isClosed;
      device.executionGate!.complete();
      await execution;
      await outcome;
      await closing;
      expect(stopped, isTrue);
      expect(device.graphs, isEmpty);
      expect(compiler.active, isNull);
    },
  );
  ComputePassDescriptor write({
    String name = 'write',
    Set<String> after = const {},
  }) => ComputePassDescriptor(
    name: name,
    program: program,
    workgroups: const Workgroups(8, 8),
    after: after,
    bindings: ShaderBindings([TextureBinding.storage(0, source)]),
    writes: [source],
  );
  RenderPassDescriptor sample({
    List<GpuResource<Object?>>? reads,
    Set<String> after = const {},
  }) => RenderPassDescriptor(
    name: 'sample',
    program: program,
    color: ColorAttachment(output),
    after: after,
    bindings: ShaderBindings([
      TextureBinding.sampled(0, source),
      SamplerBinding(1),
    ]),
    reads: reads ?? [source],
    writes: [output],
  );
  Matcher code(GraphErrorCode value) =>
      throwsA(isA<GraphException>().having((e) => e.code, 'code', value));

  test(
    'resource dependencies reorder passes and capture immutable registrations',
    () async {
      final graph = RenderGraph();
      graph.addRender(sample());
      final registration = graph.addCompute(write());
      final snapshot = graph.describe(label: 'effects');
      registration.dispose();
      final compiled = await compiler.compile(snapshot);
      expect(compiled.passNames, ['write', 'sample']);
      expect(
        compiled.lifetimes
            .firstWhere((e) => e.resourceLabel == 'density')
            .lastPass,
        1,
      );
      expect((await compiled.execute()).dispatches, 1);
      await expectLater(
        compiler.compile(graph.describe()),
        code(GraphErrorCode.uninitializedRead),
      );
      expect(compiler.active, same(compiled));
    },
  );
  test(
    'cycles and missing dependencies fail before native compilation',
    () async {
      await expectLater(
        compiler.compile(
          GraphDescription(
            passes: [
              write(after: {'sample'}),
              sample(after: {'write'}),
            ],
          ),
        ),
        code(GraphErrorCode.cycle),
      );
      expect(device.submitted, isNull);
      await expectLater(
        compiler.compile(
          GraphDescription(
            passes: [
              write(after: {'unknown'}),
            ],
          ),
        ),
        code(GraphErrorCode.missingDependency),
      );
      expect(device.submitted, isNull);
    },
  );
  test('declarations must agree with typed bindings', () async {
    await expectLater(
      compiler.compile(
        GraphDescription(
          passes: [
            write(),
            sample(reads: []),
          ],
        ),
      ),
      code(GraphErrorCode.accessMismatch),
    );
    expect(device.submitted, isNull);
  });
  test(
    'sample/write aliases are rejected even through retained references',
    () async {
      final alias = await scope.retain(source);
      final pass = ComputePassDescriptor(
        name: 'alias',
        program: program,
        workgroups: const Workgroups(1),
        bindings: ShaderBindings([
          TextureBinding.storage(0, source),
          TextureBinding.sampled(1, alias),
        ]),
        reads: [alias],
        writes: [source],
      );
      await expectLater(
        compiler.compile(GraphDescription(passes: [pass], inputs: [source])),
        code(GraphErrorCode.aliasConflict),
      );
    },
  );
  test(
    'explicit imports allow initialized reads but not missing usage',
    () async {
      await compiler.compile(
        GraphDescription(passes: [sample()], inputs: [source]),
      );
      final invalid = ComputePassDescriptor(
        name: 'bad usage',
        program: program,
        workgroups: const Workgroups(1),
        bindings: ShaderBindings([TextureBinding.storage(0, output)]),
        writes: [output],
      );
      await expectLater(
        compiler.compile(GraphDescription(passes: [invalid])),
        code(GraphErrorCode.invalidBinding),
      );
    },
  );
  test(
    'failed pipeline edit preserves active graph and successful replacement retires it',
    () async {
      final description = GraphDescription(passes: [write(), sample()]);
      final first = await compiler.compile(description);
      device.reject = true;
      await expectLater(
        compiler.compile(description),
        code(GraphErrorCode.pipelineFailed),
      );
      expect(first.isClosed, isFalse);
      expect((await first.execute()).passes, 2);
      device.reject = false;
      final second = await compiler.compile(description);
      expect(compiler.active, same(second));
      expect(first.isClosed, isTrue);
      expect(device.graphs.length, 1);
      await expectLater(first.execute(), throwsStateError);
    },
  );
  test(
    'closed/foreign owners and unsupported sample counts fail explicitly',
    () async {
      final other = ResourceScope(Device());
      final foreign = await other.createTexture(
        TextureDescriptor(width: 1, height: 1),
      );
      await expectLater(
        compiler.compile(
          GraphDescription(passes: [write()], inputs: [foreign]),
        ),
        code(GraphErrorCode.foreignResource),
      );
      await other.close();
      final multisampled = RenderPassDescriptor(
        name: 'MSAA',
        program: program,
        color: ColorAttachment(output),
        sampleCount: 4,
        writes: [output],
      );
      await expectLater(
        compiler.compile(GraphDescription(passes: [multisampled])),
        code(GraphErrorCode.unsupportedFeature),
      );
      await scope.close();
      await expectLater(
        compiler.compile(GraphDescription(passes: [write()])),
        code(GraphErrorCode.closedResource),
      );
    },
  );
  test(
    'close during compilation drains the candidate without activating it',
    () async {
      device.gate = Completer<void>();
      final pending = compiler.compile(GraphDescription(passes: [write()]));
      final rejected = expectLater(pending, throwsStateError);
      final closing = compiler.close();
      device.gate!.complete();
      await rejected;
      await closing;
      expect(compiler.active, isNull);
      expect(device.graphs, isEmpty);
    },
  );

  test('discarded attachments cannot be loaded by a later pass', () async {
    final discard = RenderPassDescriptor(
      name: 'discard',
      program: program,
      color: ColorAttachment(output, store: AttachmentStore.discard),
      writes: [output],
    );
    final load = RenderPassDescriptor(
      name: 'load',
      program: program,
      color: ColorAttachment(output, load: AttachmentLoad.load),
      reads: [output],
      writes: [output],
    );
    await expectLater(
      compiler.compile(
        GraphDescription(passes: [discard, load], inputs: [output]),
      ),
      code(GraphErrorCode.uninitializedRead),
    );
    expect(device.submitted, isNull);
  });
  test(
    'retirement failures are reported by close after a successful replacement',
    () async {
      final description = GraphDescription(passes: [write()]);
      await compiler.compile(description);
      device.releaseFailure = StateError('release failed');
      final current = await compiler.compile(description);
      expect(compiler.active, same(current));
      device.releaseFailure = null;
      await expectLater(
        compiler.close(),
        throwsA(isA<ScopeCleanupException>()),
      );
      expect(device.graphs, isEmpty);
      // This test has already observed the idempotent close failure.
      compiler = GraphCompiler(device);
    },
  );
}
