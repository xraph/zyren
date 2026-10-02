import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';
import 'blur_test.dart' show half;

void main() {
  test(
    'native SMAA stages match original GLSL under all source presets',
    () async {
      final fixture =
          jsonDecode(File('test/fixtures/smaa.json').readAsStringSync())
              as Map<String, dynamic>;
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final input = await owner.resources.createTexture(
          TextureDescriptor(
            width: 32,
            height: 24,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        final inject = await owner.materials.compileEffect(
          PostProcessDescriptor(
            program: await owner.shaders.compile(
              ShaderSource.wgsl('''
${PostProcessDescriptor.interfaceWgsl}
@group(1) @binding(0) var inputImage:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return textureLoad(inputImage,vec2<i32>(v.position.xy),0);}
'''),
            ),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, input, group: 1),
            ]),
          ),
        );
        final scene = Scene()
          ..renderSettings = RenderSettings(effects: [inject]);
        Future<Uint8List> render([int width = 32, int height = 24]) async =>
            ((await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(),
                        size: PhysicalSize(width, height),
                      ),
                    ))
                    as ReadbackOutput)
                .image
                .pixels;
        for (final preset in SmaaPreset.values) {
          final smaa = await SmaaEffect.create(
            owner,
            PhysicalSize(32, 24),
            preset: preset,
          );
          expect(smaa.stages.length, 3);
          final crowded = Scene()
            ..renderSettings = RenderSettings(effects: List.filled(30, inject));
          expect(() => smaa.attach(crowded), throwsStateError);
          expect(crowded.effects.length, 30);
          expect(() => smaa.attach(scene, order: 32767), throwsRangeError);
          expect(scene.effects, [inject]);
          final slot = smaa.attach(scene);
          final reader = owner.createChild(),
              edges = await reader.resources.retain(smaa.edges),
              weights = await reader.resources.retain(smaa.weights);
          for (final c in (fixture['cases'] as List).where(
            (c) => c['preset'] == preset.index,
          )) {
            await owner.resources.writeTexture(
              input,
              Float32List.fromList(
                (c['input'] as List)
                    .cast<num>()
                    .map((v) => v.toDouble())
                    .toList(),
              ),
            );
            final image = await render();
            for (final pair in [(edges, 'edges'), (weights, 'weights')]) {
              final data = ByteData.sublistView(
                await reader.resources.readTexture(pair.$1),
              );
              for (var i = 0; i < data.lengthInBytes ~/ 2; i++) {
                expect(
                  half(data.getUint16(i * 2, Endian.little)),
                  closeTo(
                    (c[pair.$2][i] as num).toDouble(),
                    pair.$2 == 'edges' ? .001 : 1.1 / 255,
                  ),
                  reason:
                      '${preset.name} pattern ${c['pattern']} ${pair.$2} channel $i',
                );
              }
            }
            final expected = (c['output'] as List).cast<num>();
            for (var i = 0; i < image.length; i++) {
              final a = expected[(i ~/ 4) * 4 + 3].toDouble();
              final linear = expected[i].toDouble() / math.max(a, 1e-6);
              final srgb = linear <= .0031308
                  ? 12.92 * linear
                  : 1.055 * math.pow(math.max(0, linear), 1 / 2.4) - .055;
              final value = i % 4 == 3 ? a : srgb * a;
              expect(
                image[i],
                closeTo(value.clamp(0, 1) * 255, 1.6),
                reason:
                    '${preset.name} pattern ${c['pattern']} output channel $i',
              );
            }
          }
          final next = await SmaaEffect.create(
            owner,
            PhysicalSize(33, 25),
            preset: preset,
          );
          slot.replace(next);
          await smaa.close();
          await render(33, 25);
          final closed = await SmaaEffect.create(owner, PhysicalSize(1, 1));
          await closed.close();
          expect(() => slot.replace(closed), throwsStateError);
          await render(33, 25);
          await reader.close();
          slot.dispose();
          expect(() => slot.replace(next), throwsStateError);
          await next.close();
        }
        await expectLater(
          SmaaEffect.create(owner, PhysicalSize(4096, 4096)),
          throwsArgumentError,
        );
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
