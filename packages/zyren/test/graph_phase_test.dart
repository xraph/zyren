import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'render_graph_test.dart' show Device;

void main() {
  late Device device;
  late ResourceScope resources;
  late ShaderCompiler shaders;
  late GraphCompiler compiler;
  late ShaderProgram program;
  late GpuResource<Texture> scene, density, output;
  setUp(() async {
    device = Device();
    resources = ResourceScope(device);
    shaders = ShaderCompiler(device);
    compiler = GraphCompiler(device);
    program = await shaders.compile(ShaderSource.wgsl('valid'));
    Future<GpuResource<Texture>> texture(String label) =>
        resources.createTexture(
          TextureDescriptor(
            label: label,
            width: 17,
            height: 13,
            format: TextureFormat.rgba8Unorm,
            usage: {
              TextureUsage.storage,
              TextureUsage.sampled,
              TextureUsage.renderAttachment,
            },
          ),
        );
    scene = await texture('scene');
    density = await texture('density');
    output = await texture('output');
  });
  tearDown(() async {
    await compiler.close();
    await shaders.close();
    await resources.close();
  });
  ComputePassDescriptor compute(
    String name,
    GpuResource<Texture> target, {
    Set<String> after = const {},
  }) => ComputePassDescriptor(
    name: name,
    program: program,
    workgroups: const Workgroups(1),
    after: after,
    writes: [target],
    bindings: ShaderBindings([TextureBinding.storage(0, target)]),
  );
  RenderPassDescriptor sample(
    String name,
    GpuResource<Texture> source,
    GpuResource<Texture> target,
  ) => RenderPassDescriptor(
    name: name,
    program: program,
    color: ColorAttachment(target),
    reads: [source],
    writes: [target],
    bindings: ShaderBindings([TextureBinding.sampled(0, source)]),
  );

  test(
    'phases sort local dependencies without moving work across the scene',
    () async {
      final source = GraphDescription(
        sceneColor: scene,
        output: output,
        beforeScene: [
          sample('prepare color', density, output),
          compute('density', density),
        ],
        passes: [sample('post', scene, output)],
      );
      final graph = await compiler.compile(source);
      expect(graph.passNames, ['density', 'prepare color', 'post']);
      expect(graph.beforeScenePassCount, 2);
      expect(device.submitted!.data['scenePassIndex'], 2);
      expect(graph.dispatches, 1);
      expect(graph.drawCalls, 3);
      expect(
        graph.lifetimes.firstWhere((r) => r.resourceLabel == 'scene').firstPass,
        1,
      );
      expect(() => source.beforeScene.clear(), throwsUnsupportedError);
    },
  );
  test(
    'prefix-only frames initialize their final scene output at the boundary',
    () async {
      final builder = RenderGraph();
      final registration = builder.addCompute(
        compute('prepare', density),
        stage: FramePassStage.beforeScene,
      );
      final description = builder.describe(sceneColor: scene, output: scene);
      registration.dispose();
      expect(
        builder.describe(sceneColor: scene, output: scene).beforeScene,
        isEmpty,
      );
      final graph = await compiler.compile(description);
      expect(graph.beforeScenePassCount, 1);
      expect(graph.drawCalls, 1);
      expect(graph.dispatches, 1);
      expect(
        graph.lifetimes.firstWhere((r) => r.resourceLabel == 'scene').lastPass,
        1,
      );
      await expectLater(graph.execute(), throwsA(isA<GraphException>()));
    },
  );
  test(
    'scene color cannot be imported, sampled or written before scene rendering',
    () async {
      for (final pass in [
        compute('write scene', scene),
        sample('read scene', scene, output),
      ]) {
        await expectLater(
          compiler.compile(
            GraphDescription(
              sceneColor: scene,
              output: output,
              inputs: [scene],
              beforeScene: [pass],
              passes: [sample('post', scene, output)],
            ),
          ),
          throwsA(
            isA<GraphException>().having(
              (e) => e.code,
              'code',
              GraphErrorCode.invalidDescriptor,
            ),
          ),
        );
      }
    },
  );
  test(
    'backward phase dependencies reject candidates while preserving the active graph',
    () async {
      final active = await compiler.compile(
        GraphDescription(
          sceneColor: scene,
          output: scene,
          beforeScene: [compute('prepare', density)],
          passes: [],
        ),
      );
      for (final prefix in [
        sample('before', density, output),
        compute('before', output, after: {'after'}),
      ]) {
        await expectLater(
          compiler.compile(
            GraphDescription(
              sceneColor: scene,
              output: scene,
              beforeScene: [prefix],
              passes: [compute('after', density)],
            ),
          ),
          throwsA(
            isA<GraphException>().having(
              (e) => e.code,
              'code',
              GraphErrorCode.invalidDescriptor,
            ),
          ),
        );
        expect(compiler.active, same(active));
        expect(active.isClosed, isFalse);
      }
      await expectLater(
        compiler.compile(
          GraphDescription(
            beforeScene: [compute('before', density)],
            passes: [],
          ),
        ),
        throwsA(
          isA<GraphException>().having(
            (e) => e.code,
            'code',
            GraphErrorCode.invalidDescriptor,
          ),
        ),
      );
      await expectLater(
        compiler.compile(
          GraphDescription(
            sceneColor: scene,
            output: scene,
            beforeScene: [compute('same', density)],
            passes: [compute('same', density)],
          ),
        ),
        throwsA(
          isA<GraphException>().having(
            (e) => e.code,
            'code',
            GraphErrorCode.duplicatePass,
          ),
        ),
      );
      await expectLater(
        compiler.compile(
          GraphDescription(
            sceneColor: scene,
            output: scene,
            beforeScene: [
              for (var i = 0; i < 65; i++) compute('before $i', density),
            ],
            passes: [for (var i = 0; i < 64; i++) compute('after $i', density)],
          ),
        ),
        throwsA(
          isA<GraphException>().having(
            (e) => e.code,
            'code',
            GraphErrorCode.limitExceeded,
          ),
        ),
      );
    },
  );
}
