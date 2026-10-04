import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'shared modules bind independent materials within a bounded native store',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final sourceOwner = scope.createChild();
      final bindingsOwner = scope.createChild();
      try {
        final source = await sourceOwner.shaders.compile(
          ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@vertex fn vertex(@location(0) p:vec3<f32>)->@builtin(position) vec4<f32> {
  return mesh.mvp*vec4(p,1.);
}
@fragment fn fragment()->@location(0) vec4<f32> { return meshColor(vec4(1.,0.,0.,1.)); }
'''),
        );
        final programs = <MeshShaderProgram>[];
        for (var i = 0; i < 4096; i++) {
          programs.add(await bindingsOwner.shaders.bindMesh(source));
        }
        expect((await backend.shaderStats()).livePrograms, 1);
        expect((await backend.graphStats()).liveMeshShaders, 4096);
        expect((await backend.graphStats()).meshPipelines, 1);
        await expectLater(
          bindingsOwner.shaders.bindMesh(source),
          throwsA(isA<GraphException>()),
        );
        await programs.removeLast().close();
        programs.add(await bindingsOwner.shaders.bindMesh(source));
        await sourceOwner.close();
        await expectLater(
          bindingsOwner.shaders.bindMesh(source),
          throwsStateError,
        );
        final scene = Scene()
          ..add(
            Mesh(
              PlaneGeometry(width: 2, height: 2),
              ShaderMaterial(programs.first),
            ),
          );
        final image =
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(),
                        size: PhysicalSize(8, 8),
                      ),
                    )
                    as ReadbackOutput)
                .image;
        expect(image.pixels[(4 * 8 + 4) * 4], greaterThan(200));
        await bindingsOwner.close();
        // The renderer retains materials until its scene view releases them.
        await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(8, 8),
          ),
        );
        expect((await backend.shaderStats()).livePrograms, 0);
        expect((await backend.graphStats()).liveMeshShaders, 0);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
