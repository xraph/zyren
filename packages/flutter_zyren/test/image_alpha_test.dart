import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() {
  for (final mode in AlphaMode.values) {
    testWidgets(
      'image presenter respects ${mode.name} alpha without mutation',
      (tester) async {
        final pixels = Uint8List.fromList(switch (mode) {
          AlphaMode.straight => [200, 100, 50, 128, 200, 100, 50, 0],
          AlphaMode.premultiplied => [100, 50, 25, 128, 0, 0, 0, 0],
          AlphaMode.opaque => [200, 100, 50, 0, 200, 100, 50, 0],
        });
        final original = pixels.toList();
        final presenter = ImageFramePresenter();
        final frame = RenderedFrame.fromImage(
          ImageData(pixels: pixels, size: PhysicalSize(2, 1), alphaMode: mode),
        );
        final presented = await tester.runAsync(() => presenter.present(frame));
        await tester.pumpWidget(Builder(builder: presented!.build));
        final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        expect(
          bytes!.buffer.asUint8List(),
          mode == AlphaMode.opaque
              ? [200, 100, 50, 255, 200, 100, 50, 255]
              : [100, 50, 25, 128, 0, 0, 0, 0],
        );
        expect(pixels, original);
        await tester.pumpWidget(const SizedBox());
        presented.dispose();
        await presenter.dispose();
      },
    );
  }
}
