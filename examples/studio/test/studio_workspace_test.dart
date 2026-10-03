import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio_example/studio_workspace.dart';
import 'package:zyren_studio_example/studio_theme.dart';

class _Counter extends StatefulWidget {
  const _Counter({super.key});
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('Count $count'),
  );
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('open rail tools stay highlighted in $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(brightness),
          home: Scaffold(
            body: StudioWorkspace(
              canvas: const TextButton(
                onPressed: null,
                child: Text('Viewport'),
              ),
              initialPane: 'agent',
              panes: const [
                StudioPane('scene', 'Scene', Icons.folder, Text('Scene tree')),
                StudioPane('agent', 'Agent', Icons.chat, TextField()),
              ],
            ),
          ),
        ),
      );
      Color? color(String title) => tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == title,
            ),
          )
          .style!
          .backgroundColor!
          .resolve({});
      final palette = StudioPalette.of(
        tester.element(find.byType(StudioWorkspace)),
      );
      expect(color('Scene'), palette.accent);
      expect(color('Agent'), palette.accent);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.tap(find.text('Viewport'));
      await tester.pump();
      expect(color('Scene'), palette.accent);
      expect(color('Agent'), palette.accent);
      await tester.tap(find.byTooltip('Hide Agent'));
      await tester.pump();
      expect(color('Scene'), palette.accent);
      expect(color('Agent'), Colors.transparent);
    });
  }
  testWidgets(
    'dock, hide, resize and narrow layout retain panel and viewport state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final canvas = GlobalKey();
      final agent = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioWorkspace(
              canvas: _Counter(key: canvas),
              initialPane: 'agent',
              panes: [
                StudioPane(
                  'scene',
                  'Scene',
                  Icons.account_tree,
                  const Text('Scene tree'),
                ),
                StudioPane(
                  'agent',
                  'Agent',
                  Icons.auto_awesome,
                  _Counter(key: agent),
                ),
              ],
            ),
          ),
        ),
      );
      final originalCanvas = canvas.currentState;
      final originalAgent = agent.currentState;
      await tester.tap(
        find.descendant(
          of: find.byKey(agent),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Dock Agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to bottom'));
      await tester.pumpAndSettle();
      expect(agent.currentState, same(originalAgent));
      expect(canvas.currentState, same(originalCanvas));
      expect(find.text('Count 1'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide Agent'));
      await tester.pump();
      expect(find.text('Count 1'), findsNothing);
      await tester.tap(find.byTooltip('Agent'));
      await tester.pump();
      expect(find.text('Count 1'), findsOneWidget);
      await tester.tap(find.byTooltip('Dock Agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to left'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('resize-left')),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(agent.currentState, same(originalAgent));
      tester.view.physicalSize = const Size(328, 744);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(agent.currentState, same(originalAgent));
      expect(canvas.currentState, same(originalCanvas));
      expect(find.text('Count 1'), findsOneWidget);
    },
  );
  testWidgets('right panels stack, resize and expand without losing state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final properties = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudioWorkspace(
            canvas: const Text('Viewport'),
            initialPane: 'agent',
            panes: [
              const StudioPane(
                'scene',
                'Scene',
                Icons.folder_outlined,
                Text('Hierarchy'),
              ),
              const StudioPane(
                'agent',
                'Agent',
                Icons.chat_outlined,
                Text('Conversation'),
              ),
              StudioPane(
                'inspector',
                'Properties',
                Icons.tune,
                _Counter(key: properties),
              ),
            ],
          ),
        ),
      ),
    );
    final state = properties.currentState;
    expect(
      tester.getTopLeft(find.text('Conversation')).dy,
      lessThan(tester.getTopLeft(find.text('Count 0')).dy),
    );
    await tester.drag(
      find.byKey(const ValueKey('resize-right-split')),
      const Offset(0, 60),
    );
    await tester.pump();
    expect(properties.currentState, same(state));
    await tester.tap(find.byTooltip('Hide Agent'));
    await tester.pump();
    expect(find.text('Conversation'), findsNothing);
    expect(
      tester.getTopLeft(find.byTooltip('Hide Properties')).dy,
      lessThan(100),
    );
    expect(properties.currentState, same(state));
    await tester.tap(find.byTooltip('Agent'));
    await tester.pump();
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.byKey(const ValueKey('resize-right-split')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'rail icons drag into both lower corners and bottom while preserving state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final agent = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudioWorkspace(
              canvas: const Text('Viewport'),
              initialPane: 'agent',
              panes: [
                const StudioPane(
                  'scene',
                  'Scene',
                  Icons.folder,
                  Text('Scene tree'),
                ),
                const StudioPane(
                  'assets',
                  'Assets',
                  Icons.inventory,
                  Text('Asset list'),
                ),
                StudioPane('agent', 'Agent', Icons.chat, _Counter(key: agent)),
              ],
            ),
          ),
        ),
      );
      final original = agent.currentState;
      Future<void> move(String id, String dock) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('rail-icon-$id'))),
        );
        await gesture.moveBy(const Offset(12, 24));
        await tester.pump();
        await gesture.moveTo(
          tester.getCenter(find.byKey(ValueKey('rail-drop-$dock'))),
        );
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await move('agent', 'leftLower');
      expect(find.byKey(const ValueKey('resize-left-split')), findsOneWidget);
      expect(tester.getTopLeft(find.byTooltip('Hide Agent')).dx, lessThan(400));
      expect(agent.currentState, same(original));
      await move('assets', 'right');
      await move('agent', 'rightLower');
      expect(find.byKey(const ValueKey('resize-right-split')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byTooltip('Hide Agent')).dx,
        greaterThan(800),
      );
      await move('agent', 'bottom');
      expect(
        tester.getTopLeft(find.byTooltip('Hide Agent')).dy,
        greaterThan(500),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('rail-icon-agent'))).dy,
        greaterThan(700),
      );
      final icon = tester.widget<IconButton>(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Agent'),
      );
      expect(icon.isSelected, isTrue);
      expect(agent.currentState, same(original));
      expect(tester.takeException(), isNull);
    },
  );
}
