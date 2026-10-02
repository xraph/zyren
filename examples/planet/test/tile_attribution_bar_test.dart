import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/tile_attribution_bar.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

void main() {
  testWidgets(
    'credits fit desktop and narrow views and open full data sources',
    (tester) async {
      for (final width in [1000.0, 390.0]) {
        await tester.binding.setSurfaceSize(Size(width, 700));
        final opened = <Uri>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: TileAttributionBar(
                  googleMaps: true,
                  tileCredits: const ['Alpha', 'Beta'],
                  providerCredits: const [
                    TileAttribution3D(
                      html: '<a href="https://cesium.com/">Cesium</a>',
                      collapsible: false,
                    ),
                  ],
                  onOpenLink: (uri) async {
                    opened.add(uri);
                    return true;
                  },
                ),
              ),
            ),
          ),
        );
        expect(find.text('Google Maps'), findsOneWidget);
        expect(find.text('Cesium'), findsOneWidget);
        await tester.tap(find.text('Cesium'));
        expect(opened, [Uri.parse('https://cesium.com/')]);
        await tester.tap(find.text('Data sources'));
        await tester.pumpAndSettle();
        expect(find.text('Alpha; Beta'), findsWidgets);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('provider markup cannot execute or create non-HTTPS links', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TileAttributionBar(
            providerCredits: const [
              TileAttribution3D(
                html:
                    '<script>hidden</script><a href="javascript:alert(1)">Plain credit</a>',
                collapsible: false,
              ),
            ],
            onOpenLink: (_) async {
              opened++;
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.text('hidden'), findsNothing);
    expect(find.text('Plain credit'), findsOneWidget);
    await tester.tap(find.text('Plain credit'));
    expect(opened, 0);
  });
}
