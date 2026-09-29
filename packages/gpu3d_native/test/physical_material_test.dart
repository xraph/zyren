import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/environment_checks.dart'
    show constantEnvironment, smallEnvironment;

int srgb(double linear) =>
    (255 *
            (linear <= .0031308
                ? linear * 12.92
                : 1.055 * math.pow(linear, 1 / 2.4) - .055))
        .round();

void main() {
  test(
    'physical layers retain environment response without direct lights',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      try {
        final map = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(1, 1, 1),
          resources: resources,
          quality: smallEnvironment,
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 4, height: 4), PhysicalMaterial()),
        );
        Future<int> draw(MeshMaterial material) async {
          mesh.material = material;
          final frame =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(position: const Vec3(0, 0, 2)),
                      size: PhysicalSize(31, 31),
                      environment: Environment(map: map),
                    ),
                  )
                  as ReadbackOutput;
          return frame.image.pixels[1920];
        }

        expect(
          await draw(PhysicalMaterial()),
          closeTo(await draw(StandardMaterial()), 1),
        );
        final cloth = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          specularIntensity: 0,
          sheenColor: const Color3(1, 0, 0),
        );
        expect(
          await draw(cloth),
          greaterThan(await draw(cloth.copyWith(sheenRoughness: .2))),
        );
        final black = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          specularIntensity: 0,
        );
        expect(
          await draw(black.copyWith(clearcoat: 1)),
          greaterThan(await draw(black)),
        );
      } finally {
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'untextured anisotropy supports instances, colors and morphs without UVs',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(DirectionalLight()..lookAt(const Vec3(-1, 0, -1)));
        final plane = PlaneGeometry(width: 4, height: 4);
        List<int>? reference;
        for (final instanced in [false, true]) {
          for (final deformed in [false, true]) {
            for (final colored in [false, true]) {
              final attributes = {
                VertexSemantic.position:
                    plane.attributes[VertexSemantic.position]!,
                VertexSemantic.normal: plane.attributes[VertexSemantic.normal]!,
                VertexSemantic.tangent: VertexAttribute(
                  Float32List.fromList([
                    for (var i = 0; i < plane.vertexCount; i++) ...[1, 0, 0, 1],
                  ]),
                  format: VertexFormat.float32x4,
                ),
                if (colored)
                  VertexSemantic.color: VertexAttribute(
                    Float32List.fromList(List.filled(plane.vertexCount * 4, 1)),
                    format: VertexFormat.float32x4,
                  ),
              };
              final geometry = BufferGeometry.fromAttributes(
                attributes: attributes,
                indices: plane.indices,
                morphTargets: [
                  if (deformed)
                    MorphTarget(
                      positions: List.filled(plane.vertexCount * 3, 0),
                    ),
                ],
              );
              final material = PhysicalMaterial(
                metallic: 1,
                roughness: .4,
                anisotropy: .8,
                vertexColors: colored,
              );
              final Mesh mesh = instanced
                  ? InstancedMesh(geometry, material, count: 1)
                  : Mesh(geometry, material);
              if (deformed) mesh.setMorphWeight(0, 1);
              scene.add(mesh);
              final result =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: PerspectiveCamera(
                            position: const Vec3(0, 0, 2),
                          ),
                          size: PhysicalSize(31, 31),
                        ),
                      )
                      as ReadbackOutput;
              final pixel = result.image.pixels.sublist(1920, 1924);
              reference ??= pixel;
              expect(
                pixel,
                reference,
                reason: 'instance=$instanced morph=$deformed color=$colored',
              );
              scene.remove(mesh);
            }
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'physical reflectance reaches native pixels and accepts live layer edits',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
      final plane = PlaneGeometry(width: 4, height: 4);
      final geometry = BufferGeometry.fromAttributes(
        attributes: {
          ...plane.attributes,
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < plane.vertexCount; i++) ...[1, 0, 0, 1],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: plane.indices,
      );
      final mesh = scene.add(Mesh(geometry, PhysicalMaterial()));
      final sun = scene.add(DirectionalLight());
      Future<List<int>> pixel(MeshMaterial material) async {
        mesh.material = material;
        final result =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(31, 31),
                  ),
                )
                as ReadbackOutput;
        return result.image.pixels.sublist(1920, 1924);
      }

      try {
        final standard = await pixel(StandardMaterial());
        expect(await pixel(PhysicalMaterial()), standard);
        for (final ior in [1.0, 1.5, 2.5]) {
          final value = await pixel(
            PhysicalMaterial(baseColor: const Color3(0, 0, 0), ior: ior),
          );
          // Normal incidence, roughness one: GGX D=1/pi and V=1/4.
          final f0 = math.pow((ior - 1) / (ior + 1), 2).toDouble();
          expect(value[0], closeTo(srgb(f0 / (4 * math.pi)), 1));
        }
        expect(
          await pixel(
            PhysicalMaterial(
              baseColor: const Color3(0, 0, 0),
              specularIntensity: 0,
            ),
          ),
          [0, 0, 0, 255],
        );
        final red = await pixel(
          PhysicalMaterial(
            baseColor: const Color3(0, 0, 0),
            specularColor: const Color3(1, 0, 0),
          ),
        );
        expect(red[0], greaterThan(0));
        expect(red[1], 0);
        expect(red[2], 0);
        final coat = await pixel(
          PhysicalMaterial(
            baseColor: const Color3(0, 0, 0),
            specularIntensity: 0,
            clearcoat: 1,
            clearcoatRoughness: 1,
          ),
        );
        expect(coat[0], closeTo(srgb(.04 / (4 * math.pi)), 1));
        sun.lookAt(const Vec3(-1, 0, -1));
        final brushed = PhysicalMaterial(
          metallic: 1,
          roughness: .4,
          anisotropy: .9,
        );
        final along = await pixel(brushed);
        final across = await pixel(
          brushed.copyWith(anisotropyRotation: math.pi / 2),
        );
        expect((along[0] - across[0]).abs(), greaterThan(20));
        final cloth = await pixel(
          PhysicalMaterial(
            baseColor: const Color3(0, 0, 0),
            specularIntensity: 0,
            sheenColor: const Color3(1, 0, 0),
          ),
        );
        expect(cloth[0], greaterThan(0));
        expect(cloth[1], 0);
        sun.visible = false;
        final emission = await pixel(
          PhysicalMaterial(emissive: const Color3(.5, 0, 0), clearcoat: 1),
        );
        expect(emission[0], closeTo(srgb(.5 * .96), 1));
        scene.remove(mesh);
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(31, 31),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
