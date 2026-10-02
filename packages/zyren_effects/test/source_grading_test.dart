import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'both native Hald interpolators match the original source shader',
    () async {
      final fixture =
          jsonDecode(File('test/fixtures/hald.json').readAsStringSync())
              as Map<String, dynamic>;
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final bytes = Uint8List(256);
        for (var b = 0; b < 4; b++) {
          for (var g = 0; g < 4; g++) {
            for (var r = 0; r < 4; r++) {
              bytes.setRange(
                ((b * 4 + g) * 4 + r) * 4,
                ((b * 4 + g) * 4 + r) * 4 + 4,
                [
                  (r * g * 23 + b * 71) % 256,
                  (g * b * 39 + r * 63) % 256,
                  (r * b * 47 + g * 57) % 256,
                  255,
                ],
              );
            }
          }
        }
        final lut = HaldLookup.fromImage(
          ImageData(pixels: bytes, size: PhysicalSize(8, 8)),
        );
        final input = await owner.resources.createTexture(
          TextureDescriptor(
            width: 96,
            height: 1,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        final inject = await owner.materials.compileEffect(
          PostProcessDescriptor(
            stage: PostProcessStage.display,
            program: await owner.shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var image:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return textureLoad(image,vec2<i32>(v.position.xy),0);}',
              ),
            ),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, input, group: 1),
            ]),
          ),
        );
        for (final mode in HaldInterpolation.values) {
          final cases = (fixture['cases'] as List)
              .where((c) => c['mode'] == mode.name)
              .toList();
          await owner.resources.writeTexture(
            input,
            Float32List.fromList([
              for (final c in cases)
                ...(c['input'] as List).cast<num>().map((v) => v.toDouble()),
            ]),
          );
          final grade = await ColorGradingEffect.create(
            owner,
            lut: lut,
            interpolation: mode,
          );
          final scene = Scene()
            ..renderSettings = RenderSettings(effects: [inject, grade.effect]);
          final out =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(),
                      size: PhysicalSize(96, 1),
                    ),
                  )
                  as ReadbackOutput;
          for (var i = 0; i < 96; i++) {
            for (var k = 0; k < 4; k++) {
              expect(
                out.image.pixels[i * 4 + k],
                closeTo((cases[i]['expected'][k] as num) * 255, 1),
                reason: '${mode.name} case $i channel $k',
              );
            }
          }
          await grade.close();
        }
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'dithering preserves source amplitude and channel correlation without shimmer',
    () async {
      final fixture =
          jsonDecode(File('test/fixtures/dither.json').readAsStringSync())
              as Map<String, dynamic>;
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final effect = await DitheringEffect.create(owner);
        final captured = await owner.resources.createTexture(
          TextureDescriptor(
            width: 8,
            height: 4,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.storage, TextureUsage.copySource},
          ),
        );
        final capture = await owner.materials.compileEffect(
          PostProcessDescriptor(
            stage: PostProcessStage.display,
            program: await owner.shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var outputImage:texture_storage_2d<rgba32float,write>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{let p=vec2<i32>(v.position.xy);let c=textureLoad(sceneColor,p,0);textureStore(outputImage,p,c);return c;}',
              ),
            ),
            bindings: ShaderBindings([
              TextureBinding.storage(0, captured, group: 1),
            ]),
          ),
        );
        final scene = Scene()
          ..background = const Color3(.01, .01, .01)
          ..renderSettings = RenderSettings(effects: [effect.effect, capture]);
        final out =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(8, 4),
                  ),
                )
                as ReadbackOutput;
        final data = await owner.resources.readTexture(captured);
        final encoded = Float32List.view(
          data.buffer,
          data.offsetInBytes,
          data.lengthInBytes ~/ 4,
        );
        double linear(double x) => x <= .04045
            ? x / 12.92
            : math.pow((x + .055) / 1.055, 2.4).toDouble();
        final shifts = <double>[];
        for (var i = 0; i < 32; i++) {
          final rgb = [for (var k = 0; k < 3; k++) linear(encoded[i * 4 + k])];
          final shift = rgb[2] - .01;
          shifts.add(shift);
          expect(shift.abs(), lessThanOrEqualTo(.5 / 255 + .00015));
          expect(rgb[0], closeTo(.01 + shift, .00015));
          expect(rgb[1], closeTo(.01 - shift, .00015));
          // Source sine hashes can change phase across GPU compilers. Compare
          // their full noise envelope in linear light, not a fixed byte pattern.
          final original =
              (fixture['pixels'][(3 - i ~/ 8) * 8 + i % 8][2] as num)
                  .toDouble();
          expect(rgb[2], closeTo(original - .18 + .01, 1 / 255 + .00015));
        }
        expect(shifts.where((v) => v > .0002).length, greaterThan(4));
        expect(shifts.where((v) => v < -.0002).length, greaterThan(4));
        final again =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(8, 4),
                  ),
                )
                as ReadbackOutput;
        expect(again.image.pixels, out.image.pixels);
        await effect.close();
        await owner.close();
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
