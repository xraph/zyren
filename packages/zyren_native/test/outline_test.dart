import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

const green = Color3(0, 1, 0), red = Color3(1, 0, 0);

void main() {
  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy outlines follow coverage, depth, clipping and materials',
      () async {
        final backend = await NativeBackend.create();
        final scene = Scene()..background = const Color3(0, 0, 0);
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          bottom: -1,
          top: 1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
          depthStrategy: strategy,
        );
        final group = scene.add(Group());
        final mesh = group.add(
          Mesh(PlaneGeometry(), UnlitMaterial(color: green)),
        );
        scene.outline = SceneOutline(objects: [group], color: red);
        Future<ReadbackOutput> render() async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(64, 64),
                  ),
                )
                as ReadbackOutput;
        List<int> pixel(ReadbackOutput frame, int x, int y) =>
            frame.image.pixels.sublist((y * 64 + x) * 4, (y * 64 + x) * 4 + 3);
        int edges(ReadbackOutput frame) {
          var count = 0;
          for (var i = 0; i < frame.image.pixels.length; i += 4) {
            if (frame.image.pixels[i] > 220 && frame.image.pixels[i + 1] < 30) {
              count++;
            }
          }
          return count;
        }

        try {
          final first = await render();
          expect(pixel(first, 16, 32), [255, 0, 0]);
          expect(pixel(first, 32, 32), [0, 255, 0]);
          expect(pixel(first, 15, 32), [0, 0, 0]);
          expect(first.stats.drawCalls, 3);
          expect((await backend.graphStats()).targetBytes, 64 * 64 * 4);
          final blocker = scene.add(
            Mesh(
              PlaneGeometry(width: 1.2, height: 1.2),
              UnlitMaterial(color: const Color3(0, 0, 1)),
            )..position = const Vec3(0, 0, .5),
          );
          expect(edges(await render()), 0);
          scene.remove(blocker);
          scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
          final cut = await render();
          expect(pixel(cut, 31, 32), [0, 0, 0]);
          expect(pixel(cut, 32, 32), [255, 0, 0]);
          expect(pixel(cut, 36, 32), [0, 255, 0]);
          expect(cut.stats.uploadedBytes, 0);
          scene.clippingPlanes = [];
          mesh.outlineEnabled = false;
          expect(edges(await render()), 0);
          expect((await backend.graphStats()).targetBytes, 0);
          mesh.outlineEnabled = true;
          for (final material in <MeshMaterial>[
            DiffuseMaterial(color: green),
            StandardMaterial(baseColor: green),
            UnlitMaterial(
              color: green,
              opacity: .5,
              alphaMode: MaterialAlphaMode.blend,
            ),
          ]) {
            mesh.material = material;
            expect(
              (await render()).image.pixels[(32 * 64 + 16) * 4],
              greaterThan(150),
            );
          }
          mesh.material = UnlitMaterial(
            color: green,
            colorMap: TextureMap(
              image: TextureImage.rgba(
                width: 2,
                height: 1,
                pixels: Uint8List.fromList([
                  255,
                  255,
                  255,
                  0,
                  255,
                  255,
                  255,
                  255,
                ]),
              ),
            ),
            alphaMode: MaterialAlphaMode.mask,
          );
          final holes = await render();
          expect(pixel(holes, 20, 32), [0, 0, 0]);
          expect(edges(holes), greaterThan(0));
          mesh.material = UnlitMaterial(
            color: green,
            opacity: 0,
            alphaMode: MaterialAlphaMode.blend,
          );
          expect(edges(await render()), 0);
          mesh.material = UnlitMaterial(color: green, side: MaterialSide.back);
          expect(edges(await render()), 0);
          group.remove(mesh);
          final instances = group.add(
            InstancedMesh(
              PlaneGeometry(width: .5, height: .5),
              UnlitMaterial(color: green),
              count: 2,
            ),
          );
          instances.setTransform(
            0,
            Mat4.compose(const Vec3(-.4, 0, 0), Quat.identity, Vec3.one),
          );
          instances.setTransform(
            1,
            Mat4.compose(const Vec3(.4, 0, 0), Quat.identity, Vec3.one),
          );
          expect(edges(await render()), greaterThan(0));
          group.remove(instances);
          for (final primitive in <Mesh>[
            Line(
              LineGeometry(
                points: [const Vec3(-.5, 0, 0), const Vec3(.5, 0, 0)],
              ),
              LineMaterial(color: green, width: 10),
            ),
            Points(
              PointGeometry(points: [Vec3.zero]),
              PointsMaterial(color: green, size: 20),
            ),
          ]) {
            group.add(primitive);
            expect(edges(await render()), greaterThan(0));
            group.remove(primitive);
          }
          mesh.material = UnlitMaterial(color: green);
          group.add(mesh);
          for (final samples in [1, 4]) {
            scene.renderSettings = RenderSettings(
              hdr: true,
              sampleCount: samples,
              toneMapping: ToneMapping.aces,
              bloom: BloomSettings(),
            );
            expect(edges(await render()), greaterThan(0));
          }
          scene.renderSettings = RenderSettings();
          scene.outline = null;
          expect(edges(await render()), 0);
          expect((await backend.graphStats()).targetBytes, 0);
          final shaders = backend.createShaderCompiler();
          final materials = backend.createMaterialCompiler();
          final program = await shaders.compile(
            ShaderSource.wgsl(
              '${ShaderMaterial.uniformsWgsl}\n${ShaderMaterial.vertexWgsl(uv: true)}\n'
              '''
@fragment fn fragment(input: MeshVertex) -> @location(0) vec4<f32> {
  if input.uv0.x < .5 { discard; }
  return vec4<f32>(0., 1., 0., 1.);
}
''',
            ),
          );
          final shader = await materials.compile(
            MeshShaderDescriptor(program: program, requiresUv: true),
          );
          mesh.material = ShaderMaterial(shader);
          scene.outline = SceneOutline(objects: [mesh], color: red);
          final custom = await render();
          expect(pixel(custom, 20, 32), [0, 0, 0]);
          expect(pixel(custom, 32, 32), [255, 0, 0]);
          expect(pixel(custom, 40, 32), [0, 255, 0]);
        } finally {
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }

  test('outline masks resize, remain per view and release on close', () async {
    final backend = await NativeBackend.create(),
        sibling = backend.createView();
    final scene = Scene();
    final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    scene.outline = SceneOutline(objects: [mesh]);
    FrameSubmission capture(int size) => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(size, size),
    );
    try {
      await backend.render(capture(32));
      await expectLater(
        sibling.render(capture(4096)),
        throwsA(
          isA<SceneException>()
              .having(
                (error) => error.issue.code,
                'code',
                SceneIssueCodes.renderFailed,
              )
              .having(
                (error) => '${error.issue.cause}',
                'cause',
                contains('Outline targets'),
              ),
        ),
      );
      expect((await backend.graphStats()).targetBytes, 32 * 32 * 4);
      await sibling.render(capture(64));
      expect((await backend.graphStats()).targetBytes, (32 * 32 + 64 * 64) * 4);
      await backend.render(capture(16));
      expect((await backend.graphStats()).targetBytes, (16 * 16 + 64 * 64) * 4);
      await sibling.close();
      expect((await backend.graphStats()).targetBytes, 16 * 16 * 4);
      scene.outline = null;
      await backend.render(capture(16));
      expect((await backend.graphStats()).targetBytes, 0);
    } finally {
      await sibling.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
