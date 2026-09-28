import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

BufferGeometry skinBox() {
  final base = BoxGeometry(width: .8, height: 1.4, depth: .4);
  final n = base.vertexCount;
  return BufferGeometry.fromAttributes(
    attributes: {
      ...base.attributes,
      VertexSemantic.joints: VertexAttribute(
        Uint16List.fromList([
          for (var i = 0; i < n; i++) ...[0, 1, 0, 0],
        ]),
        format: VertexFormat.uint16x4,
      ),
      VertexSemantic.weights: VertexAttribute(
        Float32List.fromList([
          for (var i = 0; i < n; i++) ...[
            .5 - base.positions[i * 3 + 1] / 1.4,
            .5 + base.positions[i * 3 + 1] / 1.4,
            0,
            0,
          ],
        ]),
        format: VertexFormat.float32x4,
      ),
      VertexSemantic.color: VertexAttribute(
        Float32List.fromList([
          for (var i = 0; i < n; i++) ...[.7, .9, .6, .8],
        ]),
        format: VertexFormat.float32x4,
      ),
    },
    indices: base.indices,
    morphTargets: [
      MorphTarget(
        name: 'widen',
        positions: [
          for (var i = 0; i < n; i++) ...[base.positions[i * 3] * .5, 0, 0],
        ],
        normals: [
          for (var i = 0; i < n; i++) ...[.03, .02, 0],
        ],
      ),
    ],
  );
}

BufferGeometry deformedReference(Mesh mesh) {
  final pose = mesh.captureDeformation()!, g = mesh.geometry.capture();
  final normals = <double>[], tangents = <double>[];
  for (var i = 0; i < g.layout.vertexCount; i++) {
    var n = Vec3(g.normals[i * 3], g.normals[i * 3 + 1], g.normals[i * 3 + 2]);
    var t = g.tangents == null
        ? const Vec3(1, 0, 0)
        : Vec3(
            g.tangents![i * 4],
            g.tangents![i * 4 + 1],
            g.tangents![i * 4 + 2],
          );
    var sign = g.tangents == null ? 1.0 : g.tangents![i * 4 + 3];
    for (var j = 0; j < pose.weights.length; j++) {
      final target = g.morphTargets[j];
      if (target.normals case final delta?) {
        n =
            n +
            Vec3(delta[i * 3], delta[i * 3 + 1], delta[i * 3 + 2]) *
                pose.weights[j];
      }
      if (target.tangents case final delta?) {
        t =
            t +
            Vec3(delta[i * 3], delta[i * 3 + 1], delta[i * 3 + 2]) *
                pose.weights[j];
      }
    }
    if (pose.matrices.isNotEmpty) {
      final sum = g.weights!.sublist(i * 4, i * 4 + 4).reduce((a, b) => a + b);
      final m = List<double>.generate(
        16,
        (c) => List<double>.generate(
          4,
          (j) =>
              pose.matrices[g.joints![i * 4 + j]].storage[c] *
              g.weights![i * 4 + j] /
              sum,
        ).reduce((a, b) => a + b),
      );
      final inverse = Mat4(m).inverted().storage;
      n = Vec3(
        inverse[0] * n.x + inverse[1] * n.y + inverse[2] * n.z,
        inverse[4] * n.x + inverse[5] * n.y + inverse[6] * n.z,
        inverse[8] * n.x + inverse[9] * n.y + inverse[10] * n.z,
      );
      t = Vec3(
        m[0] * t.x + m[4] * t.y + m[8] * t.z,
        m[1] * t.x + m[5] * t.y + m[9] * t.z,
        m[2] * t.x + m[6] * t.y + m[10] * t.z,
      );
      sign *= Mat4(m).toVectorMath().determinant().sign;
    }
    normals.addAll(n.storage);
    tangents.addAll([...t.storage, sign]);
  }
  return BufferGeometry.fromAttributes(
    attributes: {
      for (final entry in g.attributes.entries)
        if (entry.key != VertexSemantic.joints &&
            entry.key != VertexSemantic.weights)
          entry.key: entry.value,
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList([
          for (var i = 0; i < g.layout.vertexCount; i++)
            ...pose.vertexPosition(i).storage,
        ]),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        Float32List.fromList(normals),
        format: VertexFormat.float32x3,
      ),
      if (g.tangents != null)
        VertexSemantic.tangent: VertexAttribute(
          Float32List.fromList(tangents),
          format: VertexFormat.float32x4,
        ),
    },
    indices: g.indices,
  );
}

Future<void> verifyDeformationMaterials(NativeGpuBackend backend) async {
  final box = skinBox();
  final data = await const NativeTangentGenerator().generate(
    GeometryData(
      attributes: box.attributes,
      indices: box.indices,
      morphTargets: box.morphTargets,
    ),
  );
  final geometry = BufferGeometry.fromData(data);
  final color = TextureMap(
    image: TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([160, 100, 250, 180]),
    ),
  );
  final normal = TextureMap(
    image: TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([180, 155, 230, 255]),
      format: TextureFormat.rgba8Unorm,
    ),
  );
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  Future<ReadbackOutput> draw(Scene scene) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(83, 83),
            ),
          )
          as ReadbackOutput;
  final transforms = [
    Mat4.compose(
      const Vec3(-.45, 0, 0),
      Quat.identity,
      const Vec3(-.65, .8, 1),
    ),
    Mat4.compose(const Vec3(.45, 0, 0), Quat.identity, const Vec3(.65, .8, 1)),
  ];
  final materials = <MeshMaterial>[
    UnlitMaterial(),
    UnlitMaterial(vertexColors: true),
    UnlitMaterial(colorMap: color),
    UnlitMaterial(colorMap: color, vertexColors: true),
    DiffuseMaterial(color: const Color3(.4, .8, .9)),
    StandardMaterial(roughness: .7),
    StandardMaterial(vertexColors: true, roughness: .7),
    StandardMaterial(baseColorMap: color, normalMap: normal, roughness: .7),
    StandardMaterial(
      vertexColors: true,
      baseColorMap: color,
      normalMap: normal,
      roughness: .7,
    ),
    UnlitMaterial(
      colorMap: color,
      vertexColors: true,
      alphaMode: MaterialAlphaMode.mask,
      alphaCutoff: .4,
    ),
    UnlitMaterial(
      colorMap: color,
      alphaMode: MaterialAlphaMode.blend,
      opacity: .6,
    ),
  ];
  for (final instanced in [false, true]) {
    for (final material in materials) {
      final scene = Scene()..background = const Color3(0, 0, 0),
          reference = Scene()..background = const Color3(0, 0, 0);
      for (final s in [scene, reference]) {
        s.add(DirectionalLight()..lookAt(const Vec3(-.3, -.2, -1)));
      }
      final group = scene.add(Group()..scale = const Vec3(-1, 1.1, .8));
      final hip = group.add(Bone()), tip = hip.add(Bone());
      final Mesh mesh;
      if (instanced) {
        mesh = group.add(
          InstancedMesh(geometry, material, count: 2)
            ..setTransforms(0, transforms),
        );
      } else {
        mesh = group.add(
          SkinnedMesh(
            geometry,
            material,
            skin: Skin.fromBindPose(
              joints: [hip, tip],
              meshBindMatrix: group.worldMatrix,
            ),
          ),
        );
        tip.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .5);
        tip.scale = const Vec3(.8, 1.2, .7);
      }
      mesh.setMorphWeight(0, .65);
      final plain = deformedReference(mesh);
      final parent = reference.add(Group()..scale = group.scale);
      if (instanced) {
        parent.add(
          InstancedMesh(plain, material, count: 2)
            ..setTransforms(0, transforms),
        );
      } else {
        parent.add(Mesh(plain, material));
      }
      final actual = await draw(scene), expected = await draw(reference);
      var difference = 0, differentPixels = 0;
      for (var i = 0; i < actual.image.pixels.length; i += 4) {
        var pixelDifference = 0;
        for (var c = 0; c < 4; c++) {
          pixelDifference = math.max(
            pixelDifference,
            (actual.image.pixels[i + c] - expected.image.pixels[i + c]).abs(),
          );
        }
        difference = math.max(difference, pixelDifference);
        if (pixelDifference > 2) differentPixels++;
      }
      expect(
        differentPixels,
        0,
        reason:
            '${material.runtimeType}, colored ${material.vertexColors}, instanced $instanced, maximum difference $difference',
      );
    }
  }
}

Future<void> verifyDeformationShadows(NativeGpuBackend backend) async {
  final base = BoxGeometry(width: .5, height: .5, depth: .5);
  final geometry = BufferGeometry.fromAttributes(
    attributes: base.attributes,
    indices: base.indices,
    morphTargets: [
      MorphTarget(
        positions: [
          for (var i = 0; i < base.vertexCount; i++) ...[-2, 0, 0],
        ],
      ),
    ],
  );
  for (final instanced in [false, true]) {
    final scene = Scene()..background = const Color3(0, 0, 0);
    scene.add(
      Mesh(PlaneGeometry(width: 5, height: 5), StandardMaterial(roughness: 1))
        ..receiveShadow = true,
    );
    final Mesh caster = instanced
        ? InstancedMesh(
            geometry,
            UnlitMaterial(side: MaterialSide.front),
            count: 1,
          )
        : Mesh(geometry, UnlitMaterial(side: MaterialSide.front));
    scene.add(
      caster
        ..position = const Vec3(0, 0, 1)
        ..castShadow = true,
    );
    scene.add(
      DirectionalLight(
        shadow: DirectionalShadow(cascades: 2, distance: 10, normalBias: 0),
      )..lookAt(const Vec3(.6, 0, -.8)),
    );
    Future<int> probe() async {
      final frame =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: PerspectiveCamera(position: const Vec3(0, 0, 5)),
                  size: PhysicalSize(31, 31),
                ),
              )
              as ReadbackOutput;
      return frame.image.pixels[(15 * 31 + 20) * 4];
    }

    expect(await probe(), lessThan(5));
    final stats = await backend.shadowStats();
    await probe();
    expect((await backend.shadowStats()).renderedViews, stats.renderedViews);
    caster.setMorphWeight(0, 1);
    expect(await probe(), greaterThan(100));
    expect(
      (await backend.shadowStats()).renderedViews,
      stats.renderedViews + 2,
    );
  }
}

Future<void> verifyDeformationBlendOrder(NativeGpuBackend backend) async {
  final base = PlaneGeometry(width: 2, height: 2);
  final geometry = BufferGeometry.fromAttributes(
    attributes: base.attributes,
    indices: base.indices,
    morphTargets: [
      MorphTarget(
        positions: [
          for (var i = 0; i < base.vertexCount; i++) ...[0, 0, 1],
        ],
      ),
    ],
  );
  final red = UnlitMaterial(
    color: const Color3(1, 0, 0),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  final blue = UnlitMaterial(
    color: const Color3(0, 0, 1),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  final scene = Scene()..background = const Color3(0, 0, 0);
  final animated = scene.add(Mesh(geometry, red));
  scene.add(Mesh(base, blue));
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 4));
  for (final weight in [-.7, .7]) {
    animated.setMorphWeight(0, weight);
    final reference = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(Mesh(base, red)..position = Vec3(0, 0, weight))
      ..add(Mesh(base, blue));
    Future<ReadbackOutput> draw(Scene s) async =>
        await backend.render(
              FrameSubmission.capture(
                scene: s,
                camera: camera,
                size: PhysicalSize(31, 31),
              ),
            )
            as ReadbackOutput;
    expect(
      (await draw(scene)).image.pixels,
      orderedEquals((await draw(reference)).image.pixels),
    );
  }
}
