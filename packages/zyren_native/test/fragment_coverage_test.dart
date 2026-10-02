import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy complementary coverage preserves depth without uploads',
      () async {
        final backend = await NativeBackend.create();
        addTearDown(backend.close);
        final scene = Scene()..background = const Color3(0, 0, 0);
        final geometry = PlaneGeometry(width: 2, height: 2);
        final red = scene.add(
          Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))),
        );
        final blue = scene.add(
          Mesh(geometry, UnlitMaterial(color: const Color3(0, 0, 1))),
        )..position = const Vec3(0, 0, .01);
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
          depthStrategy: strategy,
        );
        Future<ReadbackOutput> render() async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(64, 64),
                  ),
                )
                as ReadbackOutput;
        await render();
        for (final progress in [0.0, .25, .5, .75, 1.0]) {
          red.fragmentCoverage = FragmentCoverage(lower: progress);
          blue.fragmentCoverage = FragmentCoverage(upper: progress);
          final frame = await render();
          var r = 0, b = 0;
          for (var i = 0; i < frame.image.pixels.length; i += 4) {
            if (frame.image.pixels[i] > 200) r++;
            if (frame.image.pixels[i + 2] > 200) b++;
          }
          expect(
            r + b,
            4096,
            reason: 'Complementary intervals must leave no holes.',
          );
          expect(b, closeTo(4096 * progress, 140));
          expect(frame.stats.uploadedBytes, 0);
        }
        red.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          emissive: const Color3(1, 0, 0),
        );
        blue.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          emissive: const Color3(0, 0, 1),
        );
        red.fragmentCoverage = FragmentCoverage(lower: .5);
        blue.fragmentCoverage = FragmentCoverage(upper: .5);
        final pbr = await render();
        var pbrRed = 0, pbrBlue = 0;
        for (var i = 0; i < pbr.image.pixels.length; i += 4) {
          if (pbr.image.pixels[i] > 200) pbrRed++;
          if (pbr.image.pixels[i + 2] > 200) pbrBlue++;
        }
        expect(pbrRed + pbrBlue, 4096);
        expect(pbrBlue, closeTo(2048, 140));
      },
    );
  }
}
