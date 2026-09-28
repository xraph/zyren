import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'HDR effects compose with depth, per-view history and premultiplied output',
    () async {
      final backend = await NativeBackend.create(),
          second = backend.createView();
      final programs = backend.createShaderCompiler(),
          compiler = backend.createMaterialCompiler();
      final scene = Scene()..background = const Color3(.25, 0, 0);
      final camera = PerspectiveCamera();
      Future<List<int>> pixel({NativeBackend? view, int size = 16}) async {
        final frame =
            await (view ?? backend).render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(size, size),
                  ),
                )
                as ReadbackOutput;
        expect(frame.image.alphaMode, AlphaMode.premultiplied);
        return frame.image.pixels.sublist(0, 4);
      }

      int srgb(double v) =>
          (255 *
                  (v <= .0031308
                      ? v * 12.92
                      : 1.055 * math.pow(v, 1 / 2.4) - .055))
              .round();
      try {
        Future<ScreenEffect> effect(
          String body,
        ) async => compiler.compileEffect(
          PostProcessDescriptor(
            program: await programs.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n'
                '@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> { $body }',
              ),
            ),
          ),
        );
        final first = await effect(
          'let p = vec2<i32>(v.position.xy); return textureLoad(sceneColor,p,0) * vec4<f32>(2.,1.,1.,1.);',
        );
        final temporal = await effect('''
let p = vec2<i32>(v.position.xy);
let c = textureLoad(sceneColor,p,0);
let h = textureLoad(historyColor,p,0) * screen.viewport.z;
let d = textureLoad(sceneDepth,p,0);
return vec4<f32>(c.rgb + h.rgb * .25, d);
''');
        scene.renderSettings = RenderSettings(
          effects: [first, temporal],
          toneMapping: ToneMapping.reinhard,
        );
        expect((await pixel())[0], closeTo(srgb(.5 / 1.5), 1));
        expect((await pixel())[0], closeTo(srgb(.625 / 1.625), 1));
        expect((await pixel(view: second))[0], closeTo(srgb(.5 / 1.5), 1));
        expect((await pixel(size: 24))[0], closeTo(srgb(.5 / 1.5), 1));
        camera.position = const Vec3(0, 0, 8);
        expect((await pixel(size: 24))[0], closeTo(srgb(.5 / 1.5), 1));
        scene.renderSettings = RenderSettings(
          effects: [first, temporal],
          toneMapping: ToneMapping.reinhard,
          historyEpoch: 1,
        );
        expect((await pixel(size: 24))[0], closeTo(srgb(.5 / 1.5), 1));
        final radiance = await effect('return vec4<f32>(4., 2., .5, 1.);');
        scene.renderSettings = RenderSettings(
          effects: [radiance],
          toneMapping: ToneMapping.aces,
        );
        final hdr = await pixel();
        for (final (i, value) in [4.0, 2.0, .5].indexed) {
          final mapped =
              (value * (2.51 * value + .03)) /
              (value * (2.43 * value + .59) + .14);
          expect(hdr[i], closeTo(srgb(mapped), 1));
        }
        await expectLater(pixel(size: 4096), throwsA(isA<Exception>()));
        expect(await pixel(), hdr);
        scene.renderSettings = RenderSettings(hdr: true, backgroundAlpha: .5);
        final alpha = await pixel();
        expect(alpha[0], closeTo(srgb(.25) * .5, 1));
        expect(alpha[3], closeTo(128, 1));
        scene.renderSettings = RenderSettings();
        await pixel();
        expect((await backend.graphStats()).targetBytes, 16 * 16 * 36);
        await second.close();
        expect((await backend.graphStats()).targetBytes, 0);
        await compiler.close();
        await programs.close();
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await backend.close();
        await second.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
