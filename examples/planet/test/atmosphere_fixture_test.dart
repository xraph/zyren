import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:planet/atmosphere_lab.dart';
import 'package:zyren/zyren.dart' as core;

void main() {
  test(
    'night preset shows catalogue stars through FXAA and restores daylight',
    () async {
      final backend = await NativeBackend.create();
      final fixture = AtmosphereFixture();
      final engine = await core.SceneEngine.create(
        scene: fixture.scene,
        camera: fixture.camera,
        backendFactory: () async => backend.createView(),
        plugins: [fixture.sky],
      );
      Future<RenderedFrame> render(int width, int height) =>
          engine.render(elapsed: Duration.zero, width: width, height: height);
      void selectHour(int hour) {
        fixture.sky.controller.date = DateTime.utc(2026, 3, 20, hour);
        fixture.setLight(hour);
      }

      try {
        final day = await render(800, 524);
        selectHour(0);
        for (final width in [800, 320]) {
          final night = await render(width, 524);
          final appearance = fixture.sky.controller.appearance;
          fixture.sky.controller.appearance = appearance.copyWith(
            starIntensity: 0,
          );
          final withoutStars = await render(width, 524);
          fixture.sky.controller.appearance = appearance;

          var visibleStarPixels = 0;
          for (var y = 0; y < 200; y++) {
            for (var x = 0; x < width; x++) {
              final offset = (y * width + x) * 4;
              var contrast = 0;
              for (var c = 0; c < 3; c++) {
                final difference =
                    night.pixels[offset + c] - withoutStars.pixels[offset + c];
                if (difference > contrast) contrast = difference;
              }
              if (contrast >= 24) visibleStarPixels++;
            }
          }
          expect(
            visibleStarPixels,
            greaterThanOrEqualTo(8),
            reason:
                'The $width-pixel night view must retain visible stars after tone mapping and FXAA.',
          );
        }
        selectHour(12);
        expect((await render(800, 524)).pixels, day.pixels);
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
