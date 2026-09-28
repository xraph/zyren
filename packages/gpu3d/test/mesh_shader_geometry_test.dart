import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'mesh_shader_test.dart' show MeshDevice;

BufferGeometry morphGeometry() {
  final source = BoxGeometry();
  return BufferGeometry.fromAttributes(
    attributes: source.attributes,
    indices: source.indices,
    morphTargets: [
      MorphTarget(positions: List.filled(source.vertexCount * 3, .01)),
    ],
  );
}

void main() {
  test(
    'geometry profiles validate visible mesh bindings before submission',
    () async {
      final device = MeshDevice();
      final owner = ShaderCompiler(device);
      try {
        for (final profile in MeshShaderGeometry.values) {
          final program = await owner.compileMesh(
            ShaderSource.wgsl('valid'),
            geometry: profile,
          );
          expect(program.geometry, profile);
          expect(device.description!.data['geometry'], profile.index);
          for (final instanced in [false, true]) {
            for (final deformed in [false, true]) {
              final geometry = deformed ? morphGeometry() : BoxGeometry();
              final material = ShaderMaterial(program);
              final mesh = instanced
                  ? InstancedMesh(geometry, material, count: 2)
                  : Mesh(geometry, material);
              final scene = Scene()..add(mesh);
              FrameSubmission capture() => FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(),
                size: PhysicalSize(4, 4),
              );
              if (profile.usesInstancing == instanced &&
                  profile.usesDeformation == deformed) {
                expect(
                  capture().scene.meshShaders.values.single,
                  same(program),
                );
              } else {
                expect(capture, throwsArgumentError);
              }
              mesh.visible = false;
              expect(capture().scene.meshShaders, isEmpty);
            }
          }
        }
      } finally {
        await owner.close();
      }
    },
  );

  test(
    'deformation reserves group two while rigid shaders can use it',
    () async {
      final device = MeshDevice();
      final compiler = ShaderCompiler(device), scope = ResourceScope(device);
      final buffer = await scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      try {
        final bindings = ShaderBindings([
          BufferBinding.uniform(0, buffer, group: 2),
        ]);
        await compiler.compileMesh(
          ShaderSource.wgsl('valid'),
          bindings: bindings,
        );
        for (final profile in [
          MeshShaderGeometry.deformed,
          MeshShaderGeometry.deformedInstanced,
        ]) {
          await expectLater(
            compiler.compileMesh(
              ShaderSource.wgsl('valid'),
              geometry: profile,
              bindings: bindings,
            ),
            throwsA(
              isA<GraphException>().having(
                (e) => e.code,
                'code',
                GraphErrorCode.invalidBinding,
              ),
            ),
          );
        }
        expect(device.materials.length, 1);
      } finally {
        await compiler.close();
        await scope.close();
      }
    },
  );

  test('custom tangent and color layouts reject missing attributes', () async {
    final owner = ShaderCompiler(MeshDevice());
    try {
      for (final layout in [
        MeshVertexLayout.positionNormalUvTangent,
        MeshVertexLayout.positionNormalColor,
        MeshVertexLayout.positionNormalUvColor,
        MeshVertexLayout.positionNormalUvTangentColor,
      ]) {
        final program = await owner.compileMesh(
          ShaderSource.wgsl('valid'),
          vertexLayout: layout,
        );
        expect(
          () => FrameSubmission.capture(
            scene: Scene()..add(Mesh(BoxGeometry(), ShaderMaterial(program))),
            camera: PerspectiveCamera(),
            size: PhysicalSize(4, 4),
          ),
          throwsArgumentError,
        );
      }
    } finally {
      await owner.close();
    }
  });

  test('public deformation prelude stays identical to the native kernel', () {
    final native = File('packages/gpu3d_native/native/src/deformation.wgsl');
    final source = native.existsSync()
        ? native
        : File('../gpu3d_native/native/src/deformation.wgsl');
    expect(
      MeshShaderInterface.deformation.trim(),
      source.readAsStringSync().trim(),
    );
  });
}
