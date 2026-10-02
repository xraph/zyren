import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native text retains counters, disconnected dots and baseline placement',
    () async {
      List<Vec2> square(double lo, double hi) => [
        Vec2(lo, lo),
        Vec2(hi, lo),
        Vec2(hi, hi),
        Vec2(lo, hi),
      ];
      final font = OutlineFont(
        unitsPerEm: 1,
        lineHeight: 1.2,
        glyphs: {
          79: GlyphOutline(
            advance: 1.2,
            shapes: [
              Shape2D(square(0, 1), holes: [square(.3, .7)]),
            ],
          ),
          105: GlyphOutline(
            advance: .4,
            shapes: [
              Shape2D(const [
                Vec2(0, 0),
                Vec2(.2, 0),
                Vec2(.2, .6),
                Vec2(0, .6),
              ]),
              Shape2D(const [
                Vec2(0, .8),
                Vec2(.2, .8),
                Vec2(.2, 1),
                Vec2(0, 1),
              ]),
            ],
          ),
        },
      );
      final backend = await NativeBackend.create();
      final camera = OrthographicCamera(
        left: -.1,
        right: 1.5,
        bottom: -.1,
        top: 1.1,
      );
      final scene = Scene()..background = null;
      try {
        for (final depth in [0.0, .2]) {
          final mesh = scene.add(
            Mesh(
              TextGeometry('Oi', font: font, depth: depth),
              UnlitMaterial(color: const Color3(1, 0, 0)),
            ),
          );
          final result =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(160, 120),
                    ),
                  )
                  as ReadbackOutput;
          int alpha(double x, double y) =>
              result.image.pixels[((110 - y * 100).floor() * 160 +
                          ((x + .1) * 100).floor()) *
                      4 +
                  3];
          expect(alpha(.5, .5), 0, reason: 'O counter at depth $depth');
          expect(alpha(.1, .5), 255);
          expect(alpha(1.3, .9), 255, reason: 'detached dot');
          expect(alpha(1.3, .7), 0, reason: 'dot gap');
          expect(alpha(1.3, .3), 255);
          scene.remove(mesh);
        }
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(160, 120),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
