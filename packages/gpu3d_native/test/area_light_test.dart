import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

int srgb(double linear) =>
    (255 *
            (linear <= .0031308
                ? linear * 12.92
                : 1.055 * math.pow(linear, 1 / 2.4) - .055))
        .round();

// Integrate projected solid angle independently on the CPU.
double reference(double width, double height, double distance) {
  var sum = 0.0;
  const count = 300;
  for (var y = 0; y < count; y++) {
    for (var x = 0; x < count; x++) {
      final px = ((x + .5) / count - .5) * width;
      final py = ((y + .5) / count - .5) * height;
      final r2 = px * px + py * py + distance * distance;
      sum += distance * distance / (r2 * r2);
    }
  }
  return sum * width * height / (count * count * math.pi);
}

double glossyReference(double roughness) {
  var sum = 0.0;
  const count = 400;
  final a2 = math.pow(roughness, 4);
  for (var y = 0; y < count; y++) {
    for (var x = 0; x < count; x++) {
      final px = ((x + .5) / count - .5) * 2;
      final py = ((y + .5) / count - .5) * 2;
      final r2 = px * px + py * py + 4;
      final nl = 2 / math.sqrt(r2);
      final nh = math.sqrt((1 + nl) / 2);
      final d = a2 / (math.pi * math.pow(nh * nh * (a2 - 1) + 1, 2));
      final visibility = .5 / (nl + math.sqrt(a2 + (1 - a2) * nl * nl));
      sum += d * visibility * nl * nl / r2;
    }
  }
  return sum * 4 / (count * count);
}

void main() {
  test(
    'finite area lighting matches integrated radiance and live edits',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(
            PlaneGeometry(width: 4, height: 4),
            PhysicalMaterial(specularIntensity: 0),
          ),
        );
        final light = scene.add(
          RectAreaLight(width: 2, height: 2)..position = const Vec3(0, 0, 2),
        );
        Future<List<int>> draw({ColorPipeline? pipeline}) async {
          final result =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      colorPipeline: pipeline,
                      camera: PerspectiveCamera(position: const Vec3(0, 0, 2)),
                      size: PhysicalSize(31, 31),
                    ),
                  )
                  as ReadbackOutput;
          return result.image.pixels.sublist(1920, 1924);
        }

        for (final dimensions in [
          (2.0, 2.0, 2.0),
          (4.0, 1.0, 2.0),
          (4.0, 4.0, 1.0),
          (1.0, 1.0, 3.0),
        ]) {
          light.width = dimensions.$1;
          light.height = dimensions.$2;
          light.position = Vec3(0, 0, dimensions.$3);
          expect(
            (await draw())[0],
            closeTo(
              srgb(reference(dimensions.$1, dimensions.$2, dimensions.$3)),
              2,
            ),
          );
        }
        light.rotateY(math.pi);
        expect(await draw(), [0, 0, 0, 255]);
        light.rotateY(math.pi);
        light.color = const Color3(1, 0, 0);
        final red = await draw();
        expect(red[0], greaterThan(0));
        expect(red.sublist(1, 3), [0, 0]);
        light.color = const Color3(1, 1, 1);
        light.width = 2;
        light.height = 2;
        light.position = const Vec3(0, 0, 2);
        mesh.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          roughness: .3,
        );
        final glossy = (await draw())[0];
        expect(glossy, greaterThan(20));
        light.width = .1;
        light.height = .1;
        expect((await draw())[0], lessThan(glossy));
        for (final roughness in [.15, .4, .8]) {
          light.width = 2;
          light.height = 2;
          mesh.material = StandardMaterial(metallic: 1, roughness: roughness);
          expect(
            (await draw())[0],
            closeTo(srgb(glossyReference(roughness)), 6),
            reason: 'GGX roughness $roughness',
          );
        }
        mesh.material = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          specularIntensity: 0,
          clearcoat: 1,
          clearcoatRoughness: .3,
        );
        expect((await draw())[0], greaterThan(20));
        mesh.material = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          specularIntensity: 0,
          sheenColor: const Color3(1, 0, 0),
        );
        expect((await draw())[0], greaterThan(0));
        light.width = 4;
        light.height = .5;
        final plane = PlaneGeometry(width: 4, height: 4);
        final anisotropic = scene.add(
          Mesh(
            BufferGeometry.fromAttributes(
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
            ),
            PhysicalMaterial(metallic: 1, roughness: .5, anisotropy: .8),
          ),
        );
        mesh.visible = false;
        final stretched = (await draw())[0];
        anisotropic.material = (anisotropic.material as PhysicalMaterial)
            .copyWith(anisotropyRotation: math.pi / 2);
        expect(((await draw())[0] - stretched).abs(), greaterThan(5));
        expect(
          (await draw(pipeline: ColorPipeline(sampleCount: 4)))[0],
          greaterThan(0),
        );
        scene.remove(anisotropic);
        scene.remove(mesh);
        await draw();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
