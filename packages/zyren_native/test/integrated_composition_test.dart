import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'screen depth reconstruction follows temporal jitter on a sloped plane',
    () async {
      final backend = await NativeBackend.create();
      final shaders = backend.createShaderCompiler();
      final materials = backend.createMaterialCompiler();
      try {
        final effect = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
  let p = scenePosition(v.uv, textureLoad(sceneDepth, vec2<i32>(v.position.xy), 0));
  // Allow subpixel raster precision, well below one jitter step.
  let onPlane = abs(p.x + p.z + 3.) < .0005;
  return select(vec4(1.,0.,0.,1.), vec4(0.,1.,0.,1.), onPlane);
}
'''),
            ),
          ),
        );
        for (final depth in DepthStrategy.values) {
          final scene = Scene()
            ..renderSettings = RenderSettings(effects: [effect]);
          scene.add(
            Mesh(PlaneGeometry(width: 4, height: 4), UnlitMaterial())
              ..rotateY(math.pi / 4),
          );
          final camera = OrthographicCamera(
            verticalSize: 2,
            near: .1,
            far: 10,
            position: const Vec3(0, 0, 3),
            depthStrategy: depth,
          );
          for (var phase = 0; phase < 8; phase++) {
            final out =
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(32, 32),
                        colorPipeline: ColorPipeline(
                          toneMapping: ToneMapping.linear,
                        ),
                        temporalAA: TemporalAAOptions(),
                      ),
                    )
                    as ReadbackOutput;
            for (final x in [12, 20]) {
              expect(
                out.image.pixels.sublist(
                  (16 * 32 + x) * 4,
                  (16 * 32 + x) * 4 + 4,
                ),
                [0, 255, 0, 255],
                reason: '$depth phase $phase',
              );
            }
          }
        }
      } finally {
        await materials.close();
        await shaders.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'core MSAA composes with clipping, outlines and reversed depth',
    () async {
      final backend = await NativeBackend.create();
      try {
        for (final depth in DepthStrategy.values) {
          final scene = Scene()..background = const Color3(0, 0, 0);
          final mesh = scene.add(
            Mesh(
              PlaneGeometry(width: 2, height: 2),
              UnlitMaterial(color: const Color3(0, 1, 0)),
            ),
          );
          scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
          scene.outline = SceneOutline(
            objects: [mesh],
            color: const Color3(1, 0, 0),
          );
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: OrthographicCamera(
                        verticalSize: 2,
                        near: .1,
                        far: 10,
                        position: const Vec3(0, 0, 3),
                        depthStrategy: depth,
                      ),
                      size: PhysicalSize(32, 32),
                      colorPipeline: ColorPipeline(
                        toneMapping: ToneMapping.linear,
                        sampleCount: 4,
                      ),
                    ),
                  )
                  as ReadbackOutput;
          List<int> pixel(int x) => output.image.pixels.sublist(
            (16 * 32 + x) * 4,
            (16 * 32 + x) * 4 + 4,
          );
          expect(pixel(8), [0, 0, 0, 255]);
          expect(pixel(24), [0, 255, 0, 255]);
          expect(pixel(16)[0], greaterThan(150));
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'screen effects, graph, reversed depth, clipping and temporal AA compose',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final graphs = backend.createGraphCompiler();
      final materials = backend.createMaterialCompiler();
      try {
        final effect = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
  let c = textureLoad(sceneColor, vec2<i32>(v.position.xy), 0);
  return vec4(0., c.r, 0., c.a);
}
'''),
            ),
          ),
        );
        Future<GpuResource<Texture>> image() => resources.createTexture(
          TextureDescriptor(
            width: 33,
            height: 33,
            format: TextureFormat.rgba16Float,
            usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
          ),
        );
        final source = await image(), output = await image();
        final shader = await shaders.compile(
          ShaderSource.wgsl('''
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4(p[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let c = textureLoad(source, vec2<i32>(pixel.xy), 0);
  return vec4(c.rgb * .5, c.a);
}
'''),
        );
        final graph = await graphs.compile(
          GraphDescription(
            sceneColor: source,
            output: output,
            passes: [
              RenderPassDescriptor(
                name: 'halve radiance',
                program: shader,
                color: ColorAttachment(output),
                reads: [source],
                writes: [output],
                bindings: ShaderBindings([TextureBinding.sampled(0, source)]),
              ),
            ],
          ),
        );
        for (final depth in DepthStrategy.values) {
          for (final withGraph in [false, true]) {
            final scene = Scene()
              ..background = const Color3(0, 0, 0)
              ..renderSettings = RenderSettings(effects: [effect]);
            final mesh = scene.add(
              Mesh(
                PlaneGeometry(width: 2, height: 2),
                UnlitMaterial(color: const Color3(.25, 0, 0)),
              ),
            );
            scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
            final camera = OrthographicCamera(
              verticalSize: 2,
              near: .1,
              far: 10,
              depthStrategy: depth,
              position: const Vec3(0, 0, 3),
            );
            Future<ReadbackOutput> draw() async =>
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(33, 33),
                        colorPipeline: ColorPipeline(
                          toneMapping: ToneMapping.linear,
                        ),
                        temporalAA: TemporalAAOptions(),
                        graph: withGraph ? graph : null,
                      ),
                    )
                    as ReadbackOutput;
            late ReadbackOutput frame;
            for (var i = 0; i < 8; i++) {
              frame = await draw();
            }
            final pixels = frame.image.pixels;
            final expected =
                (255 *
                        (1.055 * math.pow(withGraph ? .125 : .25, 1 / 2.4) -
                            .055))
                    .round();
            expect(pixels.sublist((16 * 33 + 24) * 4, (16 * 33 + 24) * 4 + 4), [
              0,
              closeTo(expected, 1),
              0,
              255,
            ]);
            expect(pixels.sublist((16 * 33 + 8) * 4, (16 * 33 + 8) * 4 + 4), [
              0,
              0,
              0,
              255,
            ]);
            mesh.fragmentCoverage = FragmentCoverage(upper: 0);
            frame = await draw();
            expect(
              frame.image.pixels.sublist(
                (16 * 33 + 24) * 4,
                (16 * 33 + 24) * 4 + 4,
              ),
              [0, 0, 0, 255],
            );
          }
        }
      } finally {
        await materials.close();
        await graphs.close();
        await shaders.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
