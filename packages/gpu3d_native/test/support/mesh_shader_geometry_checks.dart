import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'deformation_checks.dart' show skinBox, deformedReference;

String geometryShader(MeshShaderGeometry profile, MeshVertexLayout layout) =>
    '''
${MeshShaderInterface.wgsl}
${profile.usesInstancing ? MeshShaderInterface.instancing : ''}
${profile.usesDeformation ? MeshShaderInterface.deformation : ''}
@group(3) @binding(0) var<uniform> tint: vec4<f32>;
struct Vertex {
  @builtin(position) position: vec4<f32>,
  @location(0) normal: vec3<f32>,
  @location(1) tangent: vec3<f32>,
  @location(2) uv: vec2<f32>,
  @location(3) color: vec4<f32>,
  @location(4) @interpolate(flat) orientation: f32,
};
@vertex fn vertex(@builtin(vertex_index) index: u32,
    @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>
    ${layout.hasUv ? ', @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>' : ''}
    ${layout.hasTangents ? ', @location(4) tangent: vec4<f32>' : ''}
    ${layout.hasColors ? ', @location(5) color: vec4<f32>' : ''}
    ${profile.usesInstancing ? ', instance: MeshInstanceInput' : ''}) -> Vertex {
  var p = position;
  var n = normal;
  var t = ${layout.hasTangents ? 'tangent' : 'vec4(1.,0.,0.,1.)'};
  ${profile.usesDeformation ? '''let deformed = deform_vertex(index, p, n, t);
  p = deformed.position; n = deformed.normal; t = deformed.tangent;''' : ''}
  ${profile.usesInstancing ? '''p = (meshInstanceMatrix(instance) * vec4(p,1.)).xyz;
  n = meshInstanceNormalMatrix(instance) * n;
  t = vec4((meshInstanceMatrix(instance) * vec4(t.xyz,0.)).xyz, t.w * instance.normal0.w);''' : ''}
  return Vertex(mesh.mvp * vec4(p,1.), (mesh.normalMatrix * vec4(n,0.)).xyz,
    (mesh.model * vec4(t.xyz,0.)).xyz,
    ${layout.hasUv ? '(uv0 + uv1) * .5' : 'vec2(0.)'},
    ${layout.hasColors ? 'color' : 'vec4(1.)'} * ${profile.usesInstancing ? 'vec4(instance.color, 1.)' : 'vec4(1.)'},
    ${profile.usesInstancing ? 'instance.normal0.w' : '1.'});
}
@fragment fn fragment(input: Vertex, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
  ${profile.usesInstancing ? 'let facing = meshInstanceFront(front, input.orientation);' : ''}
  let color = (.15 + .35 * abs(normalize(input.normal)) +
    ${layout.hasTangents ? '.2 * abs(normalize(input.tangent))' : 'vec3(0.)'} +
    vec3(input.uv * .1, .05)) * input.color.rgb;
  return meshColor(vec4(color, input.color.a) * tint);
}
''';

Future<void> verifyMeshShaderGeometry(NativeGpuBackend backend) async {
  final shaders = backend.createShaderCompiler();
  final resources = backend.createResourceScope();
  final tint = await resources.createBuffer(
    BufferDescriptor(
      size: 16,
      usage: {BufferUsage.uniform, BufferUsage.copyDestination},
    ),
  );
  await resources.writeBuffer(tint, Float32List.fromList([1, 1, 1, 1]));
  final box = skinBox();
  final geometry = BufferGeometry.fromData(
    await const NativeTangentGenerator().generate(
      GeometryData(
        attributes: box.attributes,
        indices: box.indices,
        morphTargets: box.morphTargets,
      ),
    ),
  );
  final rigid = BufferGeometry.fromAttributes(
    attributes: {
      for (final entry in geometry.attributes.entries)
        if (entry.key != VertexSemantic.joints &&
            entry.key != VertexSemantic.weights)
          entry.key: entry.value,
    },
    indices: geometry.indices,
  );
  final morphed = BufferGeometry.fromAttributes(
    attributes: rigid.attributes,
    indices: geometry.indices,
    morphTargets: geometry.morphTargets,
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  FrameSubmission capture(Scene scene) => FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(83, 83),
  );
  Future<ReadbackOutput> draw(Scene scene) async =>
      await backend.render(capture(scene)) as ReadbackOutput;
  final programs =
      <(MeshShaderGeometry, MeshVertexLayout), MeshShaderProgram>{};
  Future<MeshShaderProgram> program(
    MeshShaderGeometry profile,
    MeshVertexLayout layout,
  ) async {
    final key = (profile, layout);
    return programs[key] ??= await shaders.compileMesh(
      ShaderSource.wgsl(
        geometryShader(profile, layout),
        label: '${profile.name}.${layout.name}',
      ),
      geometry: profile,
      vertexLayout: layout,
      bindings: ShaderBindings([BufferBinding.uniform(0, tint, group: 3)]),
    );
  }

  try {
    Scene? lastScene;
    for (final profile in MeshShaderGeometry.values) {
      for (final layout in MeshVertexLayout.values) {
        final material = ShaderMaterial(
          await program(profile, layout),
          side: MaterialSide.front,
        );
        final referenceMaterial = ShaderMaterial(
          await program(MeshShaderGeometry.rigid, layout),
          side: MaterialSide.front,
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        final hip = scene.add(Bone()), tip = hip.add(Bone());
        final Mesh mesh;
        if (profile.usesInstancing) {
          mesh = InstancedMesh(
            profile.usesDeformation ? morphed : rigid,
            material,
            count: 2,
          );
        } else if (profile.usesDeformation) {
          mesh = SkinnedMesh(
            geometry,
            material,
            skin: Skin.fromBindPose(joints: [hip, tip]),
          );
        } else {
          mesh = Mesh(rigid, material);
        }
        if (profile.usesDeformation) mesh.morphWeights = [.6];
        tip.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .45);
        tip.scale = const Vec3(1.4, .8, .7);
        mesh.scale = const Vec3(-1.1, .8, 1.2);
        scene.add(mesh);
        final expected = Scene()..background = const Color3(0, 0, 0);
        final root = expected.add(Group()..scale = mesh.scale);
        final expectedGeometry = profile.usesDeformation
            ? deformedReference(mesh)
            : rigid;
        for (var index = 0; index < (profile.usesInstancing ? 2 : 1); index++) {
          final position = profile.usesInstancing
              ? Vec3(index == 0 ? -.8 : .8, 0, 0)
              : Vec3.zero;
          final scale = profile.usesInstancing
              ? Vec3(index == 0 ? .6 : -.6, .8, .9)
              : Vec3.one;
          if (mesh is InstancedMesh) {
            mesh.setTransform(
              index,
              Mat4.compose(position, Quat.identity, scale),
            );
            mesh.setColor(
              index,
              index == 0 ? const Color3(.2, .7, 1) : const Color3(1, .3, .15),
            );
          }
          root.add(
            Mesh(
                expectedGeometry,
                referenceMaterial.copyWith(
                  color: mesh is InstancedMesh ? mesh.getColor(index) : null,
                ),
              )
              ..position = position
              ..scale = scale,
          );
        }
        lastScene = scene;
        for (final side
            in layout == MeshVertexLayout.positionNormalUvTangentColor
                ? MaterialSide.values
                : [MaterialSide.front]) {
          mesh.material = material.copyWith(side: side);
          for (final child in root.children.whereType<Mesh>()) {
            child.material = (child.material as ShaderMaterial).copyWith(
              side: side,
            );
          }
          final actual = await draw(scene), reference = await draw(expected);
          var maxDifference = 0, occupied = 0;
          for (var i = 0; i < actual.image.pixels.length; i++) {
            maxDifference = math.max(
              maxDifference,
              (actual.image.pixels[i] - reference.image.pixels[i]).abs(),
            );
            if (i % 4 != 3 && actual.image.pixels[i] > 10) occupied++;
          }
          expect(
            occupied,
            greaterThan(100),
            reason: 'Visible ${profile.name}/${layout.name}/${side.name}',
          );
          expect(
            maxDifference,
            lessThanOrEqualTo(3),
            reason: '${profile.name}/${layout.name}/${side.name}',
          );
          expect(actual.stats.drawCalls, 1);
        }
      }
    }
    expect((await backend.graphStats()).liveMeshShaders, 24);
    await resources.close();
    final scene = lastScene!;
    final frozen = capture(scene), initial = await draw(scene);
    final pipelines = (await backend.graphStats()).meshPipelines;
    final instanced = scene.children.whereType<InstancedMesh>().single;
    instanced.setMorphWeight(0, .1);
    final changed = await draw(scene);
    expect(changed.stats.uploadedBytes, 272);
    expect(changed.image.pixels, isNot(orderedEquals(initial.image.pixels)));
    instanced.setTransform(
      0,
      Mat4.compose(
        const Vec3(-.4, -.2, 0),
        Quat.identity,
        const Vec3(.6, .8, .9),
      ),
    );
    expect((await draw(scene)).stats.uploadedBytes, 128);
    instanced.setColor(0, const Color3(.9, .2, .8));
    expect((await draw(scene)).stats.uploadedBytes, 128);
    expect((await backend.graphStats()).meshPipelines, pipelines);
    expect(
      (await backend.render(frozen) as ReadbackOutput).image.pixels,
      orderedEquals(initial.image.pixels),
    );
    await draw(Scene());
  } finally {
    await shaders.close();
    await resources.close();
  }
  expect((await backend.graphStats()).liveMeshShaders, 0);
  expect((await backend.graphStats()).meshPipelines, 0);
  expect((await backend.resourceStats()).residentBytes, 0);
}
