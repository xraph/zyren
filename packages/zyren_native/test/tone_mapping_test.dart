import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test('tone mapping agrees with pinned original Three GLSL', () async {
    final fixture =
        jsonDecode(
              File(
                '../../test_assets/rendering/effects/tone.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final backend = await NativeBackend.create();
    final resources = backend.createResourceScope(),
        programs = backend.createShaderCompiler(),
        materials = backend.createMaterialCompiler();
    try {
      final input = await resources.createTexture(
        TextureDescriptor(
          width: 1,
          height: 1,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      final effect = await materials.compileEffect(
        PostProcessDescriptor(
          program: await programs.compile(
            ShaderSource.wgsl(
              '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var inputImage:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return textureLoad(inputImage,vec2<i32>(0),0);}',
            ),
          ),
          bindings: ShaderBindings([
            TextureBinding.sampled(0, input, group: 1),
          ]),
        ),
      );
      for (final c in fixture['cases'] as List) {
        final mode = ToneMapping.values.byName(c['mode'] as String);
        for (final alpha in [1.0, .5, 0.0]) {
          final values = (c['input'] as List).cast<num>();
          await resources.writeTexture(
            input,
            Float32List.fromList([...values.map((v) => v * alpha), alpha]),
          );
          final scene = Scene()
            ..renderSettings = RenderSettings(
              effects: [effect],
              toneMapping: mode,
              exposure: (c['exposure'] as num).toDouble(),
            );
          final out =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(),
                      size: PhysicalSize(2, 2),
                    ),
                  )
                  as ReadbackOutput;
          for (var k = 0; k < 3; k++) {
            final linear = (c['expected'][k] as num).clamp(0.0, 1.0);
            final encoded =
                (linear <= .0031308
                    ? linear * 12.92
                    : 1.055 * math.pow(linear, 1 / 2.4) - .055) *
                255 *
                alpha;
            expect(
              out.image.pixels[k],
              closeTo(encoded, 1.2),
              reason:
                  '${c['mode']} ${c['input']} exposure ${c['exposure']} alpha $alpha channel $k',
            );
          }
          expect(out.image.pixels[3], closeTo(alpha * 255, 1));
        }
      }
    } finally {
      await materials.close();
      await programs.close();
      await resources.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
