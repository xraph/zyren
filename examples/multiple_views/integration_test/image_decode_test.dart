import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Decoding and explicit GPU capture do not require a presented Flutter frame.
  testWidgets('decoded PNG and JPEG reach native texture pixels', (
    tester,
  ) async {
    final decoder = const NativeImageDecoder();
    final png = await rootBundle.load('assets/images/corners.png');
    final jpeg = await rootBundle.load('assets/images/gray.jpg');
    final image = TextureImage.fromImage(
      await decoder.decode(Uint8List.sublistView(png)),
    );
    final photo = TextureImage.fromImage(
      await decoder.decode(Uint8List.sublistView(jpeg)),
    );
    final backend = await NativeBackend.create();
    final scene = Scene();
    try {
      for (final (texture, uv, expected) in [
        (image, (.25, .25), [255, 0, 0, 255]),
        (image, (.75, .25), [0, 255, 0, 255]),
        (image, (.25, .75), [0, 0, 255, 255]),
        (image, (.75, .75), [255, 255, 255, 255]),
        (photo, (.5, .5), [128, 128, 128, 255]),
      ]) {
        final mesh = scene.add(
          Mesh(
            BufferGeometry(
              positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
              normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
              indices: [0, 1, 2, 0, 2, 3],
              uv0: [
                for (var i = 0; i < 4; i++) ...[uv.$1, uv.$2],
              ],
            ),
            UnlitMaterial(colorMap: TextureMap(image: texture)),
          ),
        );
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(31, 31),
                  ),
                )
                as ReadbackOutput;
        final pixel = output.image.pixels.sublist(
          (15 * 31 + 15) * 4,
          (15 * 31 + 15) * 4 + 4,
        );
        for (var channel = 0; channel < 4; channel++) {
          expect(pixel[channel], closeTo(expected[channel], 1));
        }
        scene.remove(mesh);
      }
      await backend.render(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(31, 31),
        ),
      );
      expect((await backend.resourceStats()).residentBytes, 0);
    } finally {
      await backend.close();
    }
  });
}
