import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'support.dart';

class Counter extends StatefulWidget {
  const Counter({super.key});
  @override
  State<Counter> createState() => CounterState();
}

class CounterState extends State<Counter> {
  var count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('Viewport $count'),
  );
}

Widget fixture(
  StudioEditorHostController host,
  Widget viewport, {
  FocusNode? focus,
}) => MaterialApp(
  home: Scaffold(
    body: StudioEditorHost(
      controller: host,
      viewport: viewport,
      viewportFocusNode: focus,
      workspaceBuilder: (context, panes, canvas) => Column(
        children: [
          const Text('Existing workspace'),
          Expanded(child: canvas),
          for (final pane in panes) Expanded(child: pane.child),
        ],
      ),
    ),
  ),
);

void main() {
  for (final width in [1280.0, 396.0, 328.0]) {
    testWidgets('host retains native viewport and removes open UI at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 744);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final host = makeHost();
      final viewport = GlobalKey();
      await tester.pumpWidget(fixture(host, Counter(key: viewport)));
      final original = viewport.currentState;
      expect(find.text('Existing workspace'), findsOneWidget);
      await tester.tap(find.text('Viewport 0'));
      await tester.pump();
      final lease = host.register(panelContribution('game'));
      await tester.pump();
      expect(find.byKey(const ValueKey('game.field')), findsOneWidget);
      lease.dispose();
      await tester.pump();
      expect(find.byKey(const ValueKey('game.field')), findsNothing);
      expect(viewport.currentState, same(original));
      expect(find.text('Viewport 1'), findsOneWidget);
      host.register(panelContribution('game'));
      await tester.pump();
      expect(find.byKey(const ValueKey('game.field')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await host.close();
    });
  }
  testWidgets('detaching a focused panel restores viewport focus', (
    tester,
  ) async {
    final host = makeHost();
    final focus = FocusNode(debugLabel: 'viewport');
    addTearDown(focus.dispose);
    final lease = host.register(panelContribution('game'));
    await tester.pumpWidget(
      fixture(host, const Text('Viewport'), focus: focus),
    );
    await tester.tap(find.byKey(const ValueKey('game.field')));
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    lease.dispose();
    await tester.pump();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await host.close();
  });
  testWidgets(
    'shortcuts work, retire on detach and leave text entry keys alone',
    (tester) async {
      final host = makeHost();
      var calls = 0;
      final lease = host.register(
        StudioEditorContribution(
          id: 'keys',
          version: 1,
          attach: (context) {
            context.registerCommand(
              StudioEditorCommand(
                id: 'key',
                label: 'Play',
                shortcut: const SingleActivator(LogicalKeyboardKey.keyP),
                enabled: (_) => true,
                handler: (_) => calls++,
              ),
            );
            context.registerPanel(
              StudioEditorPanel(
                id: 'field',
                title: 'Field',
                icon: Icons.edit,
                builder: (_, _) => const TextField(),
              ),
            );
          },
        ),
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        fixture(host, const Text('Viewport'), focus: focus),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(calls, 1);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(calls, 1);
      lease.dispose();
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      await host.close();
    },
  );
  testWidgets(
    'inspector, overlays and creation controls expose accessible actions',
    (tester) async {
      final host = makeHost();
      var created = 0;
      host.register(
        StudioEditorContribution(
          id: 'surfaces',
          version: 1,
          attach: (context) {
            context.registerInspector(
              StudioEditorInspector(
                id: 'inspect',
                title: 'Inspector section',
                applies: (_) => true,
                builder: (_, _) => const Text('Inspector contents'),
              ),
            );
            context.registerCreationTool(
              StudioEditorCreationTool(
                id: 'create',
                label: 'Create actor',
                icon: Icons.add,
                enabled: (_) => true,
                create: (_) => created++,
              ),
            );
            context.registerOverlay(
              StudioEditorOverlay(
                id: 'overlay',
                builder: (_, _) => const Align(
                  alignment: Alignment.topLeft,
                  child: Text('Overlay contents'),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                StudioEditorCreationTools(controller: host),
                StudioEditorInspectorSections(controller: host),
                Expanded(
                  child: StudioEditorHost(
                    controller: host,
                    viewport: const Text('Viewport'),
                    workspaceBuilder: (_, _, viewport) => viewport,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Inspector contents'), findsOneWidget);
      expect(find.text('Overlay contents'), findsOneWidget);
      expect(find.byTooltip('Create actor'), findsOneWidget);
      await tester.tap(find.text('Create actor'));
      await tester.pump();
      expect(created, 1);
      await tester.pumpWidget(const SizedBox());
      await host.close();
    },
  );
  testWidgets('missing validators are distinct from a completed validation', (
    tester,
  ) async {
    final host = makeHost();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StudioEditorProblems(controller: host)),
      ),
    );
    await tester.pump();
    expect(find.text('No validators registered'), findsOneWidget);
    expect(find.text('No validation problems'), findsNothing);
    final registration = host.register(
      StudioEditorContribution(
        id: 'validator',
        version: 1,
        attach: (context) => context.registerValidator(
          StudioEditorValidator(id: 'v', validate: (_, _) => []),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('No validation problems'), findsOneWidget);
    registration.dispose();
    await tester.pump();
    await tester.pump();
    expect(find.text('No validators registered'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await host.close();
  });
  testWidgets('play controls wrap at 328 pixels and call the active session', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(328, 744);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final host = makeHost();
    final session = TestPlaySession();
    host.register(
      StudioEditorContribution(
        id: 'play',
        version: 1,
        attach: (context) => context.registerPlayFactory(
          StudioEditorPlayFactory(
            id: 'play',
            label: 'Play project',
            supports: (_, _) => true,
            create: (_, _) async => session,
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StudioEditorPlayControls(controller: host)),
      ),
    );
    await tester.tap(find.text('Play project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.tap(find.text('Step'));
    await tester.pump();
    expect(session.steps, 1);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(session.closed, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await host.close();
  });
}
