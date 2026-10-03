// ignore_for_file: avoid_print

import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:scientific_lab/main.dart';
import '../../../test/native_volume_test.dart' as volume_checks;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  volume_checks.main(
    native: true,
    register: (name, body, {skip}) {
      testWidgets(name, (tester) async {
        await body();
      }, skip: skip as bool?);
    },
  );
  testWidgets('native scientific modes, temporal seek, picking and compact layouts', (
    tester,
  ) async {
    await tester.pumpWidget(const ScientificLab());
    final state = tester.state<ScientificWorkbenchState>(
      find.byType(ScientificWorkbench),
    );
    Future<void> ready() async {
      for (var i = 0; i < 600; i++) {
        await tester
            .pump(const Duration(milliseconds: 100))
            .timeout(const Duration(seconds: 15));
        if (state.error != null) fail(state.error!);
        if (state.viewport.status.value case SceneFailed(:final issue)) {
          fail('Native presentation failed: ${issue.message}');
        }
        if (!state.busy && state.stats != null) return;
      }
      fail('Native scientific view did not become ready.');
    }

    await ready();
    for (final mode in ScientificWorkbenchState.modes.keys) {
      final before = state.viewport.latestFrameStats!.frameId;
      final changed = state.selected != mode;
      await tester.ensureVisible(find.byKey(ValueKey('mode-$mode')));
      await tester.tap(find.byKey(ValueKey('mode-$mode')));
      await ready();
      final frameDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (changed &&
          (state.viewport.latestFrameStats?.frameId ?? before) <= before &&
          DateTime.now().isBefore(frameDeadline)) {
        await tester.pump(const Duration(milliseconds: 50));
        if (state.viewport.status.value case SceneFailed(:final issue)) {
          fail('Native $mode presentation failed: ${issue.message}');
        }
      }
      print(
        'SCIENTIFIC_FRAME_WAIT mode=$mode before=$before latest=${state.viewport.latestFrameStats?.frameId} status=${state.viewport.status.value.runtimeType} step=${state.volume.controller.settings?.sampleDistance}',
      );
      expect(state.selected, mode);
      if (changed) {
        expect(state.viewport.latestFrameStats!.frameId, greaterThan(before));
      }
      final presented = state.viewport.latestFrameStats!;
      expect(presented.readbackBytes, 0);
      expect(presented.presentationPath, isNot(PresentationPath.readback));
      // Allow integer rounding at the two-million-pixel render ceiling.
      expect(
        presented.physicalSize.width * presented.physicalSize.height,
        lessThanOrEqualTo(2004000),
      );
      expect(tester.takeException(), isNull);
      if (mode == 'Temporal') {
        await state.seek(.5);
        await ready();
        expect(state.field!.time!.time, .5);
      }
      print(
        'SCIENTIFIC_PRESENTED mode=$mode path=${presented.presentationPath.name} frame=${presented.frameId} readback=${presented.readbackBytes} size=${presented.physicalSize.width}x${presented.physicalSize.height}',
      );
    }
    await state.moveHistory(false);
    await ready();
    expect(state.selected, 'Temporal');
    expect(state.volume.controller.settings, isNull);
    await state.moveHistory(true);
    await ready();
    expect(state.selected, 'Volume');
    expect(state.volume.controller.settings, isNotNull);
    final semantics = tester.ensureSemantics();
    try {
      await tester.ensureVisible(find.byKey(const ValueKey('sample-source')));
      await tester.pump(const Duration(milliseconds: 200));
      final sample = tester.getSemantics(
        find.byKey(const ValueKey('sample-source')),
      );
      sample.owner!.performAction(sample.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('probe-value')), findsOneWidget);
      final oldValue = tester
          .widget<Text>(find.byKey(const ValueKey('probe-value')))
          .data;
      await tester.ensureVisible(find.byKey(const ValueKey('probe-0')));
      await tester.pumpAndSettle();
      final probe = tester.getSemantics(find.byKey(const ValueKey('probe-0')));
      expect(probe.getSemanticsData().label, contains('X source coordinate'));
      expect(probe.getSemanticsData().value, contains('m'));
      probe.owner!.performAction(probe.id, SemanticsAction.increase);
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('probe-value'))).data,
        isNot(oldValue),
      );
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.ensureVisible(find.text('Close'));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('undo')));
      await tester.pumpAndSettle();
      final undo = tester.getSemantics(find.byKey(const ValueKey('undo')));
      undo.owner!.performAction(undo.id, SemanticsAction.tap);
      await ready();
      expect(state.selected, 'Temporal');
      print(
        'SCIENTIFIC_KEYBOARD before focus=${FocusManager.instance.primaryFocus?.debugLabel} ancestors=${FocusManager.instance.primaryFocus?.ancestors.map((n) => n.debugLabel).toList()} busy=${state.busy} redo=${state.field!.canRedo}',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final handledRedo = await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      print('SCIENTIFIC_KEYBOARD handled=$handledRedo busy=${state.busy}');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await ready();
      expect(state.selected, 'Volume');
      final previousCamera = state.viewport.camera.position;
      await tester.tap(find.byTooltip('Camera controls'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Rotate left'));
      await tester.tap(find.text('Rotate left'));
      await tester.pumpAndSettle();
      expect(state.viewport.camera.position, isNot(previousCamera));
      await tester.tap(find.byTooltip('Camera controls'));
      state.cameraAction('Reset camera');
      await tester.pump(const Duration(milliseconds: 200));
    } finally {
      semantics.dispose();
    }
    print(
      'SCIENTIFIC_ACCESSIBILITY semantics sampling, undo, keyboard redo and camera controls',
    );
    await state.select('Isosurface');
    await ready();
    await tester.tapAt(tester.getCenter(find.byType(SceneView)));
    await tester.pump();
    expect(state.pick, isNotNull);
    final canvasSize = tester.getSize(find.byType(SceneView));
    final viewportPick = await state.agents.call(
      providerId: 'zyren.viewport',
      instanceId: 'scientific-viewport',
      tool: 'pick',
      arguments: {'x': canvasSize.width / 2, 'y': canvasSize.height / 2},
    );
    expect(viewportPick.status, AgentStatus.ok);
    final hit = (viewportPick.data['hits'] as List).first as Map;
    final joined = await state.agents.call(
      providerId: 'zyren.scientific.field',
      instanceId: 'scientific-lab',
      tool: 'sample_triangle',
      expectedRevision: state.field!.revision,
      arguments: {
        'runtimeObjectId': (hit['object'] as Map)['runtimeId'],
        'sceneRevision': viewportPick.data['sceneRevision'],
        'triangleIndex': hit['triangleIndex'],
        'barycentric': hit['barycentric'],
      },
    );
    expect(joined.status, AgentStatus.ok);
    expect(joined.data['sourceCell'], isNotNull);
    print(
      'SCIENTIFIC_AGENT_PICK runtimeObjectId=${(hit['object'] as Map)['runtimeId']} '
      'triangle=${hit['triangleIndex']} sourceCell=${joined.data['sourceCell']} '
      'canvas=${canvasSize.width}x${canvasSize.height} '
      'dpr=${tester.view.devicePixelRatio}',
    );

    final provider = 'zyren.scientific.field', instance = 'scientific-lab';
    final current = state.field!.revision;
    final command = await state.agents.call(
      providerId: provider,
      instanceId: instance,
      tool: 'set_parameters',
      expectedRevision: current,
      idempotencyKey: 'flutter-threshold',
      arguments: {'threshold': 289},
    );
    expect(command.status, AgentStatus.ok);
    expect(state.field!.revision, current + 1);
    final retry = await state.agents.call(
      providerId: provider,
      instanceId: instance,
      tool: 'set_parameters',
      expectedRevision: current,
      idempotencyKey: 'flutter-threshold',
      arguments: {'threshold': 289},
    );
    expect(retry.status, AgentStatus.ok);
    expect(state.field!.revision, current + 1);
    state.viewport.invalidate();
    await tester.pump(const Duration(milliseconds: 200));
    final historyBeforeError = state.field!.history;
    final thresholdBeforeError = state.field!.describe()['threshold'];
    state.threshold = 999;
    await state.act(
      () => state.field!.configure(
        expectedRevision: state.field!.revision,
        threshold: double.nan,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Scientific view failed'), findsOneWidget);
    expect(state.field!.history, historyBeforeError);
    expect(state.threshold, thresholdBeforeError);
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await ready();
    expect(find.text('Scientific view failed'), findsNothing);
    await state.field!.configure(
      expectedRevision: state.field!.revision,
      threshold: 500,
    );
    state.viewport.invalidate();
    await tester.pump(const Duration(milliseconds: 300));
    final emptyDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.text('No geometry at these settings').evaluate().isEmpty &&
        DateTime.now().isBefore(emptyDeadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('No geometry at these settings'), findsOneWidget);
    await tester.tap(find.text('Show slice'));
    await ready();
    final actualSize = tester.view.physicalSize;
    try {
      for (final layout in [(390.0, 1.0), (1100.0, 1.0), (320.0, 3.0)]) {
        final logicalWidth = layout.$1;
        tester.platformDispatcher.textScaleFactorTestValue = layout.$2;
        tester.view.physicalSize = Size(
          logicalWidth * tester.view.devicePixelRatio,
          720 * tester.view.devicePixelRatio,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(140));
      }
    } finally {
      tester.view.physicalSize = actualSize;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.field!.isDisposed, isTrue);
    print(
      'SCIENTIFIC_FLUTTER_COMPLETE history, accessibility, pick, commands, layouts and disposal',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
