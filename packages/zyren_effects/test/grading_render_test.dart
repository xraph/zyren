import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

double encode(double x) =>
    x <= .0031308 ? x * 12.92 : 1.055 * math.pow(x, 1 / 2.4) - .055;
void main() {
  test(
    'native Hald grading interpolates encoded color and preserves alpha',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend);
      try {
        final bytes = Uint8List(256);
        for (var b = 0; b < 4; b++) {
          for (var g = 0; g < 4; g++) {
            for (var r = 0; r < 4; r++) {
              bytes.setRange(
                ((b * 4 + g) * 4 + r) * 4,
                ((b * 4 + g) * 4 + r) * 4 + 4,
                [b * 85, r * 85, g * 85, 255],
              );
            }
          }
        }
        final lut = HaldLookup.fromImage(
          ImageData(pixels: bytes, size: PhysicalSize(8, 8)),
        );
        for (final interpolation in HaldInterpolation.values) {
          final grading = await ColorGradingEffect.create(
            scope,
            lut: lut,
            interpolation: interpolation,
            intensity: .75,
          );
          final scene = Scene()
            ..background = const Color3(.1, .3, .6)
            ..renderSettings = RenderSettings(hdr: true, backgroundAlpha: .5);
          final slot = scene.addEffect(grading.effect);
          for (final size in [PhysicalSize(4, 3), PhysicalSize(7, 5)]) {
            final out =
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(),
                        size: size,
                      ),
                    )
                    as ReadbackOutput;
            final original = [encode(.1), encode(.3), encode(.6)];
            for (var i = 0; i < out.image.pixels.length; i += 4) {
              for (var c = 0; c < 3; c++) {
                expect(
                  out.image.pixels[i + c],
                  closeTo(
                    (original[c] * .25 + original[(c + 2) % 3] * .75) *
                        .5 *
                        255,
                    1,
                  ),
                );
              }
              expect(out.image.pixels[i + 3], 128);
            }
          }
          slot.dispose();
          await grading.close();
        }
        await expectLater(
          ColorGradingEffect.create(scope, lut: lut, intensity: double.nan),
          throwsArgumentError,
        );
        await scope.close();
        expect((await backend.graphStats()).liveMaterials, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
