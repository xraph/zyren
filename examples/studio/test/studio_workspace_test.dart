import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio_example/studio_workspace.dart';

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
}
