import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shader_lab/shader_lab.dart';

class VolumeFixture extends ScenePlugin {
  @override
  String get id => 'volume-fixture';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.volumeTextures,
    RenderFeature.renderGraphs,
    RenderFeature.shaderMaterials,
  };
  late CompiledGraph graph;
  bool verified = false, detached = false;
  int executions = 0;
  @override
  Future<void> attach(PluginContext context) async {
    final volume = await context.resources.createTexture(
      TextureDescriptor(
        width: 4,
        height: 3,
        depth: 2,
        dimension: TextureDimension.d3,
        format: TextureFormat.rgba32Float,
        usage: {
          TextureUsage.storage,
          TextureUsage.copySource,
          TextureUsage.sampled,
        },
      ),
    );
    final program = await context.shaders.compile(
      ShaderSource.wgsl('''
@group(0) @binding(0) var volume: texture_storage_3d<rgba32float, write>;
@compute @workgroup_size(1, 1, 1)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  textureStore(volume, vec3<i32>(id), vec4<f32>(f32(id.x)*0.25,4.,-2.,f32(id.z)));
}
'''),
    );
    graph = await context.graphs.compile(
      GraphDescription(
        passes: [
          ComputePassDescriptor(
            name: 'volume',
            program: program,
            workgroups: const Workgroups(4, 3, 2),
            writes: [volume],
            bindings: ShaderBindings([TextureBinding.storage(0, volume)]),
          ),
        ],
      ),
    );
    await graph.execute();
    // Explicit fixture readback checks the host's GPU command transport.
    final pixels = ByteData.sublistView(
      await context.resources.readTexture(volume),
    );
    for (var z = 0; z < 2; z++) {
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 4; x++) {
          final offset = ((z * 3 + y) * 4 + x) * 16;
          final expected = [x * .25, 4.0, -2.0, z.toDouble()];
          for (var c = 0; c < 4; c++) {
            expectSync(
              pixels.getFloat32(offset + c * 4, Endian.little),
              expected[c],
            );
          }
        }
      }
    }
    final materialProgram = await context.shaders.compile(
      ShaderSource.wgsl(
        '${ShaderMaterial.uniformsWgsl}\n${ShaderMaterial.vertexWgsl()}\n'
        '''
@group(1) @binding(0) var volume: texture_3d<f32>;
@fragment fn fragment(input: MeshVertex) -> @location(0) vec4<f32> {
  let x = clamp(i32(input.position.x / mesh.viewport.x * 4.), 0, 3);
  let value = textureLoad(volume, vec3<i32>(x,0,1),0);
  return meshColor(vec4(value.rgb * vec3(1.,0.25,-0.5),1.));
}
''',
      ),
    );
    final material = await context.materials.compile(
      MeshShaderDescriptor(
        program: materialProgram,
        bindings: ShaderBindings([TextureBinding.sampled(0, volume, group: 1)]),
      ),
    );
    (context.scene.children.first as Mesh).material = ShaderMaterial(material);
    verified = true;
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    await graph.execute();
    executions++;
  }

  @override
  void detach(PluginContext context) {
    expectSync(graph.isClosed, isTrue);
    detached = true;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'plugin volume graphs share native presentation device and cleanup',
    (tester) async {
      final android = defaultTargetPlatform == TargetPlatform.android;
      final fixture = VolumeFixture();
      final controller = SceneController(
        scene: Scene()..add(Mesh(BoxGeometry(), UnlitMaterial())),
        camera: PerspectiveCamera(),
        options: EngineOptions(presentation: PresentationPolicy.requireNative),
        runtime: android
            ? SceneRuntime.nativeAndroid()
            : SceneRuntime.nativeMetal(),
      );
      controller.use(fixture);
      controller.use(ShaderLabPlugin());
      controller.scene.renderSettings = RenderSettings(
        toneMapping: ToneMapping.aces,
      );
      var frames = 0;
      final listener = controller.frameStats.listen((stats) {
        expectSync(stats.readbackBytes, 0);
        frames++;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SceneView(controller: controller)),
        ),
      );
      Future<void> waitFrame(int previous) async {
        for (var i = 0; i < 240; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('$issue');
          }
          if (frames > previous) return;
          if (i % 10 == 0) controller.invalidate();
        }
        fail('Graph-backed native frame did not arrive.');
      }

      await waitFrame(0);
      expect(fixture.verified, isTrue);
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await waitFrame(frames);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      await listener.cancel();
      expect(fixture.detached, isTrue);
      final counts = (await MethodChannel(
        android ? 'zyren/android-surfaces' : 'zyren/scene-views',
      ).invokeMapMethod<Object?, Object?>('diagnostics'))!;
      for (final key in ['sessions', 'renderers', 'retiring']) {
        expect(counts[key], 0);
      }
      expect(counts[android ? 'surfaces' : 'heldDrawables'], 0);
      debugPrint(
        'Native graph cleanup: $counts; graph executions=${fixture.executions}',
      );
      await tester.binding.setSurfaceSize(null);
    },
  );
}
