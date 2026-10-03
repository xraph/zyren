import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import 'package:zyren_studio_example/studio_editor.dart';
import 'studio_editor_test.dart' show MemoryStore;

class ViewportProbe extends StatefulWidget {
  const ViewportProbe({super.key});
  @override
  State<ViewportProbe> createState() => ViewportProbeState();
}

class ViewportProbeState extends State<ViewportProbe> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  for (final width in [1200.0, 328.0]) {
    testWidgets(
      'real editor adds and detaches contribution without replacing viewport at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 744);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final viewport = GlobalKey<ViewportProbeState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: studioTheme(Brightness.dark),
            home: StudioEditor(
              document: starterScene(),
              store: MemoryStore(),
              saveLocation: '/test/scene',
              viewportBuilder: (_) => ViewportProbe(key: viewport),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        final original = viewport.currentState;
        final state = tester.state<StudioEditorState>(
          find.byType(StudioEditor),
        );
        final lease = state.editorHost.register(
          StudioEditorContribution(
            id: 'game.test',
            version: 1,
            attach: (context) {
              context.registerPanel(
                StudioEditorPanel(
                  id: 'game.test.panel',
                  title: 'Game tools',
                  defaultDock: StudioEditorDock.leftLower,
                  initiallyOpen: true,
                  icon: Icons.sports_esports,
                  builder: (_, _) =>
                      const TextField(key: ValueKey('game.test.field')),
                ),
              );
            },
          ),
        );
        await tester.pump();
        if (width > 600) {
          expect(find.byKey(const ValueKey('game.test.field')), findsOneWidget);
          expect(
            tester.getTopLeft(find.byTooltip('Hide Game tools')).dx,
            lessThan(400),
          );
          await tester.tap(find.byTooltip('Hide Game tools'));
          await tester.pump();
        }
        final pane = width > 600
            ? find.byTooltip('Game tools')
            : find.text('Game tools');
        await tester.ensureVisible(pane.first);
        await tester.tap(pane.first);
        await tester.pump();
        expect(find.byKey(const ValueKey('game.test.field')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('game.test.field')));
        await tester.pump();
        lease.dispose();
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('game.test.field')), findsNothing);
        expect(viewport.currentState, same(original));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
