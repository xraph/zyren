import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scientific_lab/controls.dart';

void main() {
  for (final layout in [
    (390.0, 1.0),
    (390.0, 2.0),
    (320.0, 3.0),
    (1100.0, 1.0),
  ]) {
    testWidgets('controls meet accessibility guidelines at $layout', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(layout.$1, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        for (final selected in scientificModes) {
          await tester.pumpWidget(
            MaterialApp(
              theme: scientificTheme(),
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(layout.$2),
                  ),
                  child: SingleChildScrollView(
                    child: ScientificControls(
                      selected: selected,
                      unit: 'K',
                      presentation: 'Native view ready',
                      busy: false,
                      ready: true,
                      canUndo: true,
                      canRedo: true,
                      undoLabel: 'Change time',
                      redoLabel: 'Change time',
                      time: 1,
                      threshold: 293,
                      onMode: (_) {},
                      onCamera: (_) {},
                      onPreview: (_) {},
                      onCommit: (_) {},
                      onUndo: () {},
                      onRedo: () {},
                      onSample: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await tester.ensureVisible(
            find.byKey(const ValueKey('sample-source')),
          );
          await tester.pumpAndSettle();
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        }
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'screen-reader actions, units, selected state and keyboard activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var undos = 0, samples = 0;
        double? preview, committed;
        String? mode;
        await tester.pumpWidget(
          MaterialApp(
            theme: scientificTheme(),
            home: Scaffold(
              body: ScientificControls(
                selected: 'Isosurface',
                unit: 'K',
                presentation: 'Native view ready',
                busy: false,
                ready: true,
                canUndo: true,
                canRedo: false,
                undoLabel: 'Change parameters',
                redoLabel: '',
                time: 1,
                threshold: 293,
                onMode: (v) => mode = v,
                onCamera: (_) {},
                onPreview: (v) => preview = v,
                onCommit: (v) => committed = v,
                onUndo: () => undos++,
                onRedo: () {},
                onSample: () => samples++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.byKey(const ValueKey('mode-Isosurface'))),
          matchesSemantics(
            label: 'Isosurface',
            isSelected: true,
            hasSelectedState: true,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
        final slider = tester.getSemantics(
          find.byKey(const ValueKey('field-slider')),
        );
        expect(
          slider.getSemanticsData().label,
          contains('Isosurface threshold'),
        );
        expect(slider.getSemanticsData().value, '293.0 kelvin');
        slider.owner!.performAction(slider.id, SemanticsAction.increase);
        await tester.pump();
        expect(preview, greaterThan(293));
        expect(committed, preview);
        final undo = tester.getSemantics(find.byKey(const ValueKey('undo')));
        expect(undo.getSemanticsData().label, contains('Undo'));
        expect(
          tester
              .getSemantics(find.byTooltip('Camera controls'))
              .getSemanticsData()
              .label,
          'Camera controls',
        );
        undo.owner!.performAction(undo.id, SemanticsAction.tap);
        await tester.pump();
        expect(undos, 1);
        final sample = tester.getSemantics(
          find.byKey(const ValueKey('sample-source')),
        );
        sample.owner!.performAction(sample.id, SemanticsAction.tap);
        await tester.pump();
        expect(samples, 1);
        for (var i = 0; i < 12 && mode == null; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pump();
        }
        expect(mode, isNotNull);
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('source sampling remains labelled and usable with large text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final scale in [1.0, 3.0]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 844);
        var closes = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: scientificTheme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SingleChildScrollView(
                  child: ScientificProbe(
                    maximum: const [2, 2, 2],
                    unit: 'm',
                    enabled: true,
                    sample: (p) => 'Scalar ${p[0].toStringAsFixed(3)} K',
                    onClose: () => closes++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        final node = tester.getSemantics(find.byKey(const ValueKey('probe-0')));
        expect(node.getSemanticsData().label, 'X source coordinate');
        expect(node.getSemanticsData().value, contains('m'));
        final previous = tester
            .widget<Text>(find.byKey(const ValueKey('probe-value')))
            .data;
        node.owner!.performAction(node.id, SemanticsAction.increase);
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('probe-value'))).data,
          isNot(previous),
        );
        await tester.tap(find.text('Close'));
        expect(closes, 1);
      }
    } finally {
      semantics.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
