import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/widgets/lab_shell.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = Platform.environment['OCEAN_LAYOUT_FONTS'];
    if (fonts == null) return;
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(font.key)
        ..addFont(
          File(
            '$fonts/${font.value}',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await loader.load();
    }
  });
  for (final size in [
    const Size(1440, 900),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('controls fit ${size.width} by ${size.height}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scenes = OceanLabSceneDefinition.decode(
        File('assets/ocean/scenes.json').readAsStringSync(),
      );
      String? selected;
      var paused = false;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto'),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: OceanLabShell(
              scenes: scenes,
              sceneId: 'coast',
              detail: OceanLabDetail.balanced,
              debug: OceanWaterDebug.color,
              paused: false,
              route: false,
              busy: false,
              layers: const {
                'ocean.surface': true,
                'ocean.foam': true,
                'ocean.underwater': true,
              },
              status: 'Tick 120 · FFT 32 · 192 patches · 26 MiB planned',
              evidence: 'Owned synthetic coast. Layout test canvas.',
              onScene: (value) => selected = value,
              onDetail: (_) {},
              onDebug: (_) {},
              onLayer: (_, _) {},
              onPause: () => paused = true,
              onReset: () {},
              onRoute: () {},
              canvas: const ColoredBox(
                color: Color(0xff122832),
                child: Center(
                  child: Text('Layout fixture: native canvas mounts here'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('lab-canvas'))).height,
        greaterThan(size.height * .40),
      );
      await tester.tap(find.byTooltip('Pause simulation'));
      expect(paused, isTrue);
      await tester.tap(find.text('Shallow coast'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open water').last);
      await tester.pumpAndSettle();
      expect(selected, 'calm');
      expect(tester.takeException(), isNull);
      final output = Platform.environment['OCEAN_LAYOUT_CAPTURE'];
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File(
            '$output/layout-${size.width.toInt()}x${size.height.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
