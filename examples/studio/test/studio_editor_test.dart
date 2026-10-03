import 'package:flutter/material.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/studio_editor.dart';

class MemoryStore implements StudioStore {
  StudioDocument? saved;
  bool fail = false;
  @override
  Future<StudioDocument?> read() async {
    if (fail) throw StateError('Storage offline');
    return saved;
  }

  @override
  Future<void> write(StudioDocument document) async {
    if (fail) throw StateError('Storage offline');
    saved = StudioDocument.decode(document.encode());
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(1200, 800),
      const Size(396, 844),
      const Size(328, 744),
    ]) {
      testWidgets(
        'save, reload and failure at ${size.width} logical pixels in $brightness',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final store = MemoryStore();
          await tester.pumpWidget(
            MaterialApp(
              theme: studioTheme(brightness),
              home: StudioEditor(
                document: starterScene(),
                store: store,
                saveLocation: '/test/scene.json',
                viewportBuilder: (_) => const ColoredBox(color: Colors.black),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull);
          expect(find.text('Unsaved changes'), findsOneWidget);
          await tester.tap(find.text('Tour'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Select and place objects'), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('Next'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Build your scene'), findsOneWidget);
          await tester.tap(find.text('Next'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Keep your changes'), findsOneWidget);
          await tester.tap(find.text('Finish tour'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Save'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(store.saved!.nodes.length, 3);
          expect(find.text('Saved'), findsOneWidget);
          await tester.tap(find.text('Reload'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Saved scene reloaded'), findsOneWidget);
          final state = tester.state<StudioEditorState>(
            find.byType(StudioEditor),
          );
          final registry = state.agents;
          expect(
            (registry.discover()['providers'] as List).map(
              (p) => p['providerId'],
            ),
            containsAll([
              'zyren.studio',
              'zyren.viewport',
              'zyren.timeline',
              'zyren.engineering',
              'zyren.devtools',
            ]),
          );
          final screen = await registry.call(
            providerId: state.agentProvider.id,
            instanceId: state.agentProvider.instanceId,
            tool: 'state',
          );
          expect(screen.status, AgentStatus.ok);
          expect((screen.data['screen'] as Map)['agentProviderGaps'], isEmpty);
          expect((screen.data['screen'] as Map)['pixelVisibility'], 'unknown');
          expect((screen.data['screen'] as Map)['devicePixelRatio'], 1);
          if (size.width <= 396) {
            expect(
              (screen.data['screen'] as Map)['logicalRect']['width'],
              size.width,
            );
          }

          store.fail = true;
          await tester.tap(find.text('Save'));
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.textContaining('Save failed:'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('missing save and empty scene remain distinct', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: studioTheme(Brightness.dark),
        home: StudioEditor(
          document: StudioDocument(id: 'empty', title: 'Empty', nodes: []),
          store: MemoryStore(),
          saveLocation: '/missing',
          initiallySaved: true,
          viewportBuilder: (_) => const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Reload'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('No saved scene yet'), findsOneWidget);
    expect(find.text('Renderer unavailable'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
