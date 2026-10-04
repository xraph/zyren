import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'mesh_shader_test.dart' show MeshDevice;
import 'frame_graph_test.dart' show FrameBackend;

class _MeshOnlyBackend extends FrameBackend {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'mesh without scene inputs',
    features: {RenderFeature.meshShaders},
    limits: super.capabilities.limits,
  );
}

void main() {
  test('scene input capability is checked before backend submission', () async {
    final device = MeshDevice(), backend = _MeshOnlyBackend();
    final owner = ShaderCompiler(device);
    final program = await owner.compileMesh(
      ShaderSource.wgsl('fixture'),
      sceneInputs: MeshSceneInputs.opaqueColorDepth,
    );
    final engine = await SceneEngine.create(
      scene: Scene()..add(Mesh(BoxGeometry(), ShaderMaterial(program))),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
    );
    try {
      await expectLater(
        engine.renderFrame(elapsed: Duration.zero, width: 8, height: 8),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.requiredFeatures,
            'missing capability',
            contains(RenderFeature.meshSceneInputs),
          ),
        ),
      );
      expect(backend.last, isNull);
    } finally {
      await engine.dispose();
      await owner.close();
    }
  });
  test(
    'scene inputs reserve group three only for opted-in mesh programs',
    () async {
      final device = MeshDevice();
      final shaders = ShaderCompiler(device), resources = ResourceScope(device);
      try {
        final buffer = await resources.createBuffer(
          BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
        );
        final input = ShaderBindings([
          BufferBinding.uniform(0, buffer, group: 3),
        ]);
        await expectLater(
          shaders.compileMesh(
            ShaderSource.wgsl('fixture'),
            sceneInputs: MeshSceneInputs.opaqueColorDepth,
            bindings: input,
          ),
          throwsA(
            isA<GraphException>().having(
              (e) => e.code,
              'code',
              GraphErrorCode.invalidBinding,
            ),
          ),
        );
        expect(device.description, isNull);
        final plain = await shaders.compileMesh(
          ShaderSource.wgsl('fixture'),
          bindings: input,
        );
        expect(plain.sceneInputs, MeshSceneInputs.none);
        final program = await shaders.compileMesh(
          ShaderSource.wgsl('fixture'),
          sceneInputs: MeshSceneInputs.opaqueColorDepth,
          geometry: MeshShaderGeometry.deformedInstanced,
          bindings: ShaderBindings([
            BufferBinding.uniform(0, buffer, group: 1),
          ]),
        );
        expect(program.sceneInputs, MeshSceneInputs.opaqueColorDepth);
        expect(device.description!.data['sceneInputs'], 1);
        expect(device.description!.data['geometry'], 3);
      } finally {
        await shaders.close();
        await resources.close();
      }
    },
  );
}
