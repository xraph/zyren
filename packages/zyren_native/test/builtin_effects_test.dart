import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

int srgb(double x) =>
    (255 * (x <= .0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - .055))
        .round();
void main() {
  test('FXAA matches pinned Three r184 display-space reference pixels', () async {
    final fixture =
        jsonDecode(
              File(
                '../../test_assets/rendering/effects/fxaa.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final width = fixture['width'] as int, height = fixture['height'] as int;
    final backend = await NativeBackend.create();
    final resources = backend.createResourceScope(),
        shaders = backend.createShaderCompiler(),
        materials = backend.createMaterialCompiler();
    try {
      final image = await resources.createTexture(
        TextureDescriptor(
          width: width,
          height: height,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      final effect = await materials.compileEffect(
        PostProcessDescriptor(
          program: await shaders.compile(
            ShaderSource.wgsl(
              '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var inputImage:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {return textureLoad(inputImage,vec2<i32>(v.position.xy),0);}',
            ),
          ),
          bindings: ShaderBindings([
            TextureBinding.sampled(0, image, group: 1),
          ]),
        ),
      );
      for (final c in fixture['cases'] as List) {
        await resources.writeTexture(
          image,
          Float32List.fromList(
            (c['input'] as List).cast<num>().map((v) => v.toDouble()).toList(),
          ),
        );
        final scene = Scene()
          ..renderSettings = RenderSettings(
            effects: [effect],
            spatialAntialiasing: SpatialAntialiasing.fxaa,
            toneMapping: c['toneMapping'] == 'none'
                ? ToneMapping.none
                : ToneMapping.reinhard,
          );
        final result =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(width, height),
                  ),
                )
                as ReadbackOutput;
        final expected = c['expected'] as List;
        for (var i = 0; i < expected.length; i++) {
          expect(
            result.image.pixels[i],
            closeTo(expected[i] as int, 1),
            reason: '${c['name']} pixel ${i ~/ 4} channel ${i % 4}',
          );
        }
      }
    } finally {
      await materials.close();
      await shaders.close();
      await resources.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'bloom extracts HDR before exposure, normalizes levels and preserves coverage',
    () async {
      final backend = await NativeBackend.create(),
          second = backend.createView();
      final shaders = backend.createShaderCompiler(),
          materials = backend.createMaterialCompiler();
      final scene = Scene()..background = const Color3(.5, .5, .5);
      final camera = PerspectiveCamera();
      Future<Uint8List> render({
        int width = 32,
        int height = 32,
        NativeBackend? view,
      }) async =>
          (await (view ?? backend).render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(width, height),
                    ),
                  )
                  as ReadbackOutput)
              .image
              .pixels;
      try {
        final gain = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {let c=textureLoad(sceneColor,vec2<i32>(v.position.xy),0);return c*vec4<f32>(4.,4.,4.,1.);}',
              ),
            ),
          ),
        );
        scene.renderSettings = RenderSettings(
          effects: [gain],
          hdr: true,
          toneMapping: ToneMapping.reinhard,
        );
        final original = await render();
        expect(original[0], closeTo(srgb(2 / 3), 1));
        for (final levels in [1, 3, 6]) {
          scene.renderSettings = RenderSettings(
            effects: [gain],
            toneMapping: ToneMapping.reinhard,
            bloom: BloomSettings(
              intensity: .5,
              threshold: 1,
              softKnee: 0,
              levels: levels,
            ),
          );
          final pixels = await render(width: 33, height: 21);
          for (var i = 0; i < pixels.length; i += 4) {
            expect(pixels[i], closeTo(srgb(2.5 / 3.5), 1));
            expect(pixels[i + 3], 255);
          }
        }
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(intensity: .5, threshold: 2, softKnee: .5),
        );
        expect((await render())[0], closeTo(srgb(2.125 / 3.125), 1));
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(intensity: .5, threshold: 1, softKnee: 0),
          exposure: .5,
        );
        expect((await render())[0], closeTo(srgb(1.25 / 2.25), 1));
        scene.renderSettings = scene.renderSettings.copyWith(
          backgroundAlpha: .5,
        );
        final alpha = await render();
        // Stored radiance 1, threshold 1: no glow. Coverage remains half.
        expect(alpha[0], closeTo(srgb(1 / 2) * .5, 1));
        expect(alpha[3], closeTo(128, 1));
        final impulse = await materials.compileEffect(
          PostProcessDescriptor(
            program: await shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
let p=vec2<i32>(v.position.xy);
return vec4<f32>(select(vec3<f32>(0.),vec3<f32>(8.,2.,0.), all(p==vec2<i32>(16))),1.);
}
'''),
            ),
          ),
        );
        scene.renderSettings = RenderSettings(
          effects: [impulse],
          bloom: BloomSettings(
            intensity: .2,
            threshold: 0,
            softKnee: 0,
            levels: 4,
          ),
        );
        final glow = await render();
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(
            intensity: .2,
            threshold: 0,
            softKnee: 0,
            levels: 1,
          ),
        );
        final singleLevel = await render();
        double linear(int value) {
          final v = value / 255;
          return v <= .04045
              ? v / 12.92
              : math.pow((v + .055) / 1.055, 2.4).toDouble();
        }

        final energy = [0.0, 0.0];
        for (var p = 0; p < 32 * 32; p++) {
          if (p == 16 * 32 + 16) continue;
          for (var channel = 0; channel < 2; channel++) {
            energy[channel] += linear(singleLevel[p * 4 + channel]);
          }
        }
        // A 2x2 box and bilinear reconstruction conserve the impulse. The central
        // pixel clips at output, removing .225 red and .05625 green from the halo.
        expect(energy[0], closeTo(1.375, .015));
        expect(energy[1], closeTo(.34375, .01));
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(
            intensity: .2,
            threshold: 0,
            softKnee: 0,
            levels: 4,
          ),
        );
        expect(await render(), glow);
        expect(glow[(16 * 32 + 15) * 4], greaterThan(0));
        expect(glow[(16 * 32 + 12) * 4], greaterThan(0));
        expect(glow[(16 * 32 + 15) * 4], greaterThan(glow[(16 * 32 + 12) * 4]));
        for (var i = 0; i < glow.length; i += 4) {
          expect(glow[i + 2], 0);
          expect(glow[i + 3], 255);
        }
        // Zero intensity avoids pyramid allocation and reproduces the source.
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(intensity: 0),
        );
        final disabled = await render();
        expect(disabled[(16 * 32 + 15) * 4], 0);
        expect((await backend.graphStats()).targetBytes, 32 * 32 * 36);
        scene.renderSettings = scene.renderSettings.copyWith(
          bloom: BloomSettings(
            intensity: .2,
            threshold: 0,
            softKnee: 0,
            levels: 4,
          ),
        );
        expect(await render(), glow);
        final bytes = (await backend.graphStats()).targetBytes;
        expect(bytes, greaterThan(32 * 32 * 36));
        expect(bytes, lessThan(32 * 32 * 42));
        expect(await render(view: second), glow);
        expect((await backend.graphStats()).targetBytes, bytes * 2);
        await expectLater(
          render(width: 2048, height: 2048),
          throwsA(isA<SceneException>()),
        );
        expect(await render(), glow);
        scene.renderSettings = scene.renderSettings.copyWith(clearBloom: true);
        final noGlow = await render();
        expect(noGlow[(16 * 32 + 15) * 4], 0);
        expect((await backend.graphStats()).targetBytes, bytes + 32 * 32 * 36);
        scene.renderSettings = RenderSettings();
        await render();
        await second.close();
        expect((await backend.graphStats()).targetBytes, 0);
      } finally {
        await materials.close();
        await shaders.close();
        await second.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'FXAA filters final color and alpha without blurring flat fields',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(.18, .18, .18);
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<Uint8List> render() async =>
          (await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(32, 32),
                    ),
                  )
                  as ReadbackOutput)
              .image
              .pixels;
      try {
        scene.renderSettings = RenderSettings(hdr: true, backgroundAlpha: .5);
        final flat = await render();
        scene.renderSettings = scene.renderSettings.copyWith(
          spatialAntialiasing: SpatialAntialiasing.fxaa,
        );
        expect(await render(), flat);
        for (final color in [const Color3(1, 1, 1), const Color3(0, 0, 0)]) {
          final mesh = scene.add(
            Mesh(
              PlaneGeometry(width: 1, height: 1),
              UnlitMaterial(color: color),
            )..rotateZ(.35),
          );
          scene.renderSettings = RenderSettings(backgroundAlpha: 0, hdr: true);
          final raw = await render();
          scene.renderSettings = scene.renderSettings.copyWith(
            spatialAntialiasing: SpatialAntialiasing.fxaa,
          );
          final filtered = await render();
          expect(filtered, isNot(raw));
          final partial = [
            for (var i = 3; i < filtered.length; i += 4)
              if (filtered[i] > 0 && filtered[i] < 255) i,
          ];
          expect(partial, isNotEmpty);
          for (final i in partial) {
            for (var c = 1; c <= 3; c++) {
              expect(filtered[i - c], closeTo(color.r * filtered[i], 1));
            }
          }
          scene.remove(mesh);
        }
        expect((await backend.graphStats()).targetBytes, 32 * 32 * 36);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
