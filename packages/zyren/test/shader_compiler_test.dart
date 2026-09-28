import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class Backend implements ShaderBackend {
  final Device device;
  final compilers = <ShaderCompiler>[];
  bool closed = false;
  Backend(this.device);
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'shader fake',
    features: {RenderFeature.shaderCompilation},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 1024),
  );
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) {
    final compiler = ShaderCompiler(device, label: label);
    compilers.add(compiler);
    return compiler;
  }

  @override
  ResourceScope createResourceScope({String label = ''}) =>
      throw UnimplementedError();
  @override
  Future<FrameOutput> render(FrameSubmission submission) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {
    closed = true;
    for (final compiler in compilers) {
      await compiler.close();
    }
  }
}

class Device implements ShaderDevice {
  Completer<void>? gate;
  final live = <Object, int>{};
  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    await gate?.future;
    if (source.code == 'invalid') {
      throw ShaderCompilationException(source, [
        ShaderDiagnostic(
          message: 'Invalid expression',
          severity: ShaderDiagnosticSeverity.error,
          location: const ShaderLocation(
            line: 2,
            column: 3,
            offset: 8,
            length: 1,
          ),
        ),
      ]);
    }
    final key = Object();
    live[key] = 1;
    return ShaderBuild(
      key: key,
      entryPoints: [
        const ShaderEntryPoint(
          name: 'main',
          stage: ShaderStage.compute,
          workgroupSize: (8, 8, 1),
        ),
      ],
    );
  }

  @override
  Future<void> retainShader(Object key) async {
    live[key] = live[key]! + 1;
  }

  @override
  Future<void> releaseShader(Object key) async {
    final next = live[key]! - 1;
    if (next == 0) {
      live.remove(key);
    } else {
      live[key] = next;
    }
  }
}

void main() {
  test(
    'plugin compilers are lazy attachment owners and close before detach',
    () async {
      final device = Device(), events = <String>[];
      final backend = Backend(device);
      late ShaderCompiler compiler;
      late ShaderProgram program;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          TestPlugin(
            'effect',
            events,
            onAttach: (context) async {
              compiler = context.shaders;
              expect(context.shaders, same(compiler));
              program = await compiler.compile(ShaderSource.wgsl('valid'));
            },
            onDetach: (context) {
              expect(program.isClosed, isTrue);
              expect(device.live, isEmpty);
              expect(() => context.shaders, throwsStateError);
            },
          ),
          TestPlugin('no shaders', events),
        ],
      );
      expect(backend.compilers.length, 1);
      await engine.dispose();
      expect(backend.closed, isTrue);
    },
  );
  test(
    'attachment cancellation drains shader work and failed attachment cleans up',
    () async {
      final device = Device()..gate = Completer<void>();
      final backend = Backend(device), lifetime = AttachmentScope();
      final attaching = Completer<void>();
      final engine = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        lifetime: lifetime,
        plugins: [
          TestPlugin(
            'effect',
            [],
            onAttach: (context) async {
              final pending = context.shaders.compile(
                ShaderSource.wgsl('valid'),
              );
              attaching.complete();
              await pending;
            },
          ),
        ],
      );
      final outcome = expectLater(engine, throwsA(isA<SceneException>()));
      await attaching.future;
      lifetime.close();
      expect(backend.compilers.single.isClosed, isTrue);
      device.gate!.complete();
      await outcome;
      expect(device.live, isEmpty);
      expect(backend.closed, isTrue);
      final next = Backend(Device());
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => next,
          plugins: [
            TestPlugin(
              'failed',
              [],
              onAttach: (context) async {
                await context.shaders.compile(ShaderSource.wgsl('valid'));
                throw StateError('attach failed');
              },
            ),
          ],
        ),
        throwsStateError,
      );
      expect(next.device.live, isEmpty);
      expect(next.closed, isTrue);
    },
  );
  test('shader access on an unsupported backend reports the plugin', () async {
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
              context.shaders;
            },
          ),
        ],
      ),
      throwsA(
        isA<SceneException>()
            .having(
              (e) => e.issue.code,
              'code',
              SceneIssueCodes.unsupportedFeature,
            )
            .having((e) => e.issue.pluginId, 'plugin', 'weather'),
      ),
    );
  });
  test(
    'programs carry immutable metadata and retire with their compiler',
    () async {
      final device = Device();
      final scope = ShaderCompiler(device, label: 'effects');
      final program = await scope.compile(
        ShaderSource.wgsl('valid', label: 'heatmap'),
      );
      expect(program.source.label, 'heatmap');
      expect(program.entryPoints.single.workgroupSize, (8, 8, 1));
      expect(() => program.entryPoints.clear(), throwsUnsupportedError);
      expect(program.isClosed, isFalse);
      await scope.close();
      await scope.close();
      expect(program.isClosed, isTrue);
      expect(device.live, isEmpty);
      await expectLater(
        scope.compile(ShaderSource.wgsl('valid')),
        throwsStateError,
      );
    },
  );
  test(
    'closing during compile drains the result without publishing it',
    () async {
      final device = Device()..gate = Completer<void>();
      final compiler = ShaderCompiler(device);
      final pending = compiler.compile(ShaderSource.wgsl('valid'));
      final outcome = expectLater(pending, throwsStateError);
      final closed = compiler.close();
      device.gate!.complete();
      await outcome;
      await closed;
      expect(device.live, isEmpty);
    },
  );
  test(
    'retained programs survive their original compiler and reject foreign devices',
    () async {
      final device = Device();
      final first = ShaderCompiler(device), second = ShaderCompiler(device);
      final foreign = ShaderCompiler(Device());
      final original = await first.compile(ShaderSource.wgsl('valid'));
      final retained = await second.retain(original);
      await expectLater(foreign.retain(original), throwsArgumentError);
      await first.close();
      expect(retained.isClosed, isFalse);
      expect(device.live.values.single, 1);
      await expectLater(second.retain(original), throwsStateError);
      await second.close();
      await foreign.close();
      expect(device.live, isEmpty);
    },
  );
  test(
    'compiler diagnostics preserve source identity and do not poison later compilation',
    () async {
      final device = Device(),
          source = ShaderSource.wgsl('invalid', label: 'weather');
      final compiler = ShaderCompiler(device);
      await expectLater(
        compiler.compile(source),
        throwsA(
          isA<ShaderCompilationException>()
              .having((e) => e.source, 'source', same(source))
              .having((e) => e.diagnostics.single.location!.line, 'line', 2),
        ),
      );
      await compiler.compile(ShaderSource.wgsl('valid'));
      await compiler.close();
      expect(device.live, isEmpty);
    },
  );
  test('source admission bounds UTF-8 storage and labels', () {
    expect(() => ShaderSource.wgsl(''), throwsArgumentError);
    expect(() => ShaderSource.wgsl('é' * 524289), throwsArgumentError);
    expect(
      () => ShaderSource.wgsl('valid', label: 'a' * 1025),
      throwsArgumentError,
    );
  });
}
