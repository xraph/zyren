import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/mesh_shader_checks.dart';
import 'support/mesh_shader_geometry_checks.dart';

void main() {
  test('custom geometry profiles match rigid reference meshes', () async {
    final backend = await NativeBackend.create();
    try {
      await verifyMeshShaderGeometry(backend);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  test(
    'mesh UV textures, pipeline variants and scene effects share native ownership',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyMeshShaders(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'mesh attachment alias rejection leaves the native device usable',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyMeshAttachmentAlias(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'custom indexed mesh shaders render transforms and retained uniforms',
    () async {
      final backend = await NativeBackend.create();
      final observer = backend.createView();
      final resources = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      try {
        final buffer = await resources.createBuffer(
          BufferDescriptor(
            size: 16,
            usage: {BufferUsage.uniform, BufferUsage.copyDestination},
          ),
        );
        await resources.writeBuffer(buffer, Float32List.fromList([1, 0, 0, 1]));
        final program = await shaders.compileMesh(
          ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@group(1) @binding(0) var<uniform> tint: vec4<f32>;
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(p, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> { return meshColor(tint); }
''', label: 'test mesh'),
          bindings: ShaderBindings([
            BufferBinding.uniform(0, buffer, group: 1),
          ]),
        );
        final scene = Scene()..background = const Color3(0, 0, 1);
        final mesh = Mesh(
          PlaneGeometry(width: 2, height: 2),
          ShaderMaterial(program),
        );
        scene.add(mesh);
        Future<ReadbackOutput> draw([NativeBackend? view]) async =>
            await (view ?? backend).render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(17, 13),
                  ),
                )
                as ReadbackOutput;
        final red = await draw();
        expect((await draw(observer)).image.pixels, red.image.pixels);
        final foreign = await NativeBackend.create();
        try {
          await expectLater(draw(foreign), throwsA(isA<SceneException>()));
        } finally {
          await foreign.close();
        }

        final legacy = await NativeRenderer.create();
        try {
          await expectLater(
            legacy.render(scene, PerspectiveCamera(), width: 17, height: 13),
            throwsUnsupportedError,
          );
        } finally {
          await legacy.dispose();
        }
        final center = (6 * 17 + 8) * 4;
        expect(red.image.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        expect(red.image.pixels.sublist(0, 4), [0, 0, 255, 255]);
        await resources.writeBuffer(buffer, Float32List.fromList([0, 1, 0, 1]));
        expect((await draw()).image.pixels.sublist(center, center + 4), [
          0,
          255,
          0,
          255,
        ]);
        await resources.close();
        expect((await draw()).image.pixels.sublist(center, center + 4), [
          0,
          255,
          0,
          255,
        ]);
        mesh.position = const Vec3(5, 0, 0);
        expect((await draw()).image.pixels.sublist(center, center + 4), [
          0,
          0,
          255,
          255,
        ]);
        mesh.position = Vec3.zero;
        final second = await shaders.compileMesh(
          ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(p, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> { return meshColor(vec4(1.)); }
'''),
        );
        final other = scene.add(
          Mesh(PlaneGeometry(), ShaderMaterial(second))
            ..position = const Vec3(5, 0, 0),
        );
        final pending = draw();
        final closing = shaders.close();
        expect((await pending).image.pixels.sublist(center, center + 4), [
          0,
          255,
          0,
          255,
        ]);
        await closing;
        expect(
          () => FrameSubmission.capture(
            scene: scene,
            camera: PerspectiveCamera(),
            size: PhysicalSize(17, 13),
          ),
          throwsStateError,
        );
        scene.remove(mesh);
        scene.remove(other);
        await draw();
        await draw(observer);
        await backend.close();
        expect((await observer.resourceStats()).residentBytes, 0);
        expect((await observer.shaderStats()).livePrograms, 0);
      } finally {
        await shaders.close();
        await resources.close();
        await backend.close();
        await observer.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
