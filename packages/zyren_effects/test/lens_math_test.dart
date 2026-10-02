import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_effects/src/lens_wgsl.dart';
import 'package:zyren_native/zyren_native.dart';
import 'blur_test.dart' show half;

void main() {
  test(
    'lens threshold and features match original GLSL and image orientation',
    () async {
      final fixture =
          jsonDecode(File('test/fixtures/lens.json').readAsStringSync())
              as Map<String, dynamic>;
      final backend = await NativeBackend.create(),
          root = GpuScope.fromBackend(backend);
      try {
        for (final kind in ['threshold', 'features']) {
          final scope = root.createChild();
          final input = await scope.resources.createTexture(
            TextureDescriptor(
              width: 16,
              height: 12,
              format: TextureFormat.rgba32Float,
              usage: {TextureUsage.sampled, TextureUsage.copyDestination},
            ),
          );
          final uniform = await scope.resources.createBuffer(
            BufferDescriptor(
              size: 32,
              usage: {BufferUsage.uniform, BufferUsage.copyDestination},
            ),
          );
          final target = await scope.resources.createTexture(
            TextureDescriptor(
              width: kind == 'threshold' ? 8 : 16,
              height: kind == 'threshold' ? 6 : 12,
              format: TextureFormat.rgba16Float,
              usage: {TextureUsage.renderAttachment, TextureUsage.copySource},
            ),
          );
          final inject = await scope.materials.compileEffect(
            PostProcessDescriptor(
              program: await scope.shaders.compile(
                ShaderSource.wgsl(
                  '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var inputImage:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return textureLoad(inputImage,vec2<i32>(v.position.xy),0);}',
                ),
              ),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, input, group: 1),
              ]),
            ),
          );
          final effect = await scope.materials.compileEffect(
            PostProcessDescriptor(
              target: target,
              program: await scope.shaders.compile(
                ShaderSource.wgsl(
                  kind == 'threshold' ? lensThresholdWgsl : lensFeaturesWgsl,
                ),
              ),
              bindings: ShaderBindings([
                BufferBinding.uniform(0, uniform, group: 2),
                if (kind == 'features')
                  TextureBinding.sampled(0, input, group: 1),
              ]),
            ),
          );
          final scene = Scene()
            ..renderSettings = RenderSettings(effects: [inject, effect]);
          for (final c in (fixture['cases'] as List).where(
            (c) => c['kind'] == kind,
          )) {
            final setting = c['setting'] as int;
            await scope.resources.writeTexture(
              input,
              Float32List.fromList(
                (c['input'] as List)
                    .cast<num>()
                    .map((v) => v.toDouble())
                    .toList(),
              ),
            );
            await scope.resources.writeBuffer(
              uniform,
              Float32List.fromList([
                setting < 2 ? 10 : 0,
                setting.isOdd ? 1 : .5,
                setting == 0
                    ? .001
                    : setting == 1
                    ? .3
                    : 0,
                setting == 0
                    ? .001
                    : setting == 1
                    ? 0
                    : .2,
                setting == 2 ? 0 : 10,
                .005,
                kind == 'threshold' ? 8 : 16,
                kind == 'threshold' ? 6 : 12,
              ]),
            );
            await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(),
                size: PhysicalSize(16, 12),
              ),
            );
            final data = ByteData.sublistView(
              await scope.resources.readTexture(target),
            );
            for (var i = 0; i < (c['expected'] as List).length; i++) {
              final expected = (c['expected'][i] as num).toDouble();
              expect(
                half(data.getUint16(i * 2, Endian.little)),
                closeTo(expected, math.max(.00002, expected.abs() * .004)),
                reason:
                    '$kind pattern ${c['pattern']} setting $setting channel $i',
              );
            }
          }
          await scope.close();
          expect((await backend.resourceStats()).residentBytes, 0);
        }
      } finally {
        await root.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
