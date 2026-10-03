import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/photorealistic_layout.dart';
import 'package:planet/tile_attribution_bar.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

void main() {
  testWidgets(
    'responsive panels preserve canvas size and leave scene input open',
    (tester) async {
      for (final size in [
        const Size(320, 568),
        const Size(390, 844),
        const Size(600, 960),
        const Size(834, 1194),
        const Size(1024, 768),
        const Size(1440, 900),
        const Size(844, 390),
        const Size(320, 320),
      ]) {
        for (final scale in [1.0, 2.0]) {
          await tester.binding.setSurfaceSize(size);
          var sceneTaps = 0;
          var sceneMounts = 0;
          var sceneDisposals = 0;
          var settingTaps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SafeArea(
                  child: PhotorealisticLayout(
                    scene: _SceneProbe(
                      onTap: () => sceneTaps++,
                      onMount: () => sceneMounts++,
                      onDispose: () => sceneDisposals++,
                    ),
                    controls: Column(
                      children: [
                        for (var index = 0; index < 12; index++)
                          TextButton(
                            onPressed: () => settingTaps++,
                            child: Text('Setting $index'),
                          ),
                      ],
                    ),
                    info: const Text('24 tiles · 3 loading'),
                    attribution: const TileAttributionBar(
                      googleMaps: true,
                      tileCredits: ['Map imagery'],
                      showSourcesButton: false,
                      providerCredits: [
                        TileAttribution3D(
                          html: 'Provider credit',
                          collapsible: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final canvas = find.byKey(const ValueKey('photorealistic-scene'));
          final original = tester.getRect(canvas);
          final controls = find.byKey(const ValueKey('controls-panel'));
          final info = find.byKey(const ValueKey('info-panel'));
          expect(controls, size.width >= 1000 ? findsOneWidget : findsNothing);
          if (controls.evaluate().isEmpty) {
            await tester.tap(find.byKey(const ValueKey('controls-toggle')));
            await tester.pumpAndSettle();
          }
          final panel = tester.getRect(controls);
          expect(panel.left, 12);
          if (size.width >= 600) {
            expect(panel.width, 320);
            expect(panel.top, 68);
          } else {
            expect(panel.width, size.width - 24);
            expect(panel.top, greaterThanOrEqualTo(60));
          }
          expect(tester.getRect(canvas), original);
          // Pointer input remains reachable outside the panel.
          await tester.tapAt(Offset(size.width - 8, 60));
          expect(sceneTaps, 1);
          final setting = find.text('Setting 11');
          await tester.ensureVisible(setting);
          await tester.pumpAndSettle();
          await tester.tap(setting);
          expect(settingTaps, 1);
          expect(sceneTaps, 1);
          await tester.tap(find.byKey(const ValueKey('info-toggle')));
          await tester.pumpAndSettle();
          expect(controls, findsNothing);
          expect(info, findsOneWidget);
          expect(find.text('24 tiles · 3 loading'), findsOneWidget);
          expect(tester.getRect(canvas), original);
          await tester.tap(find.byKey(const ValueKey('panel-close')));
          await tester.pumpAndSettle();
          expect(info, findsNothing);
          expect(find.text('24 tiles · 3 loading'), findsNothing);
          expect(find.text('Provider credit'), findsOneWidget);
          expect(find.text('Google Maps'), findsOneWidget);
          expect(tester.getRect(canvas), original);
          expect(tester.takeException(), isNull, reason: '$size at $scale');
          expect(sceneMounts, 1);
          expect(sceneDisposals, 0);
          await tester.pumpWidget(const SizedBox());
          expect(sceneDisposals, 1);
        }
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'resize keeps the active panel and Escape restores toggle focus',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PhotorealisticLayout(
              scene: SizedBox.expand(),
              controls: Text('Options'),
              info: Text('Sources'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('info-toggle')));
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('info-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('controls-panel')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('info-panel')), findsNothing);
      final toggle = tester.widget<IconButton>(
        find.byKey(const ValueKey('info-toggle')),
      );
      expect(toggle.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );
}

class _SceneProbe extends StatefulWidget {
  final VoidCallback onTap, onMount, onDispose;
  const _SceneProbe({
    required this.onTap,
    required this.onMount,
    required this.onDispose,
  });
  @override
  State<_SceneProbe> createState() => _SceneProbeState();
}

class _SceneProbeState extends State<_SceneProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    behavior: HitTestBehavior.opaque,
    child: const ColoredBox(color: Color(0xff213947)),
  );
}
