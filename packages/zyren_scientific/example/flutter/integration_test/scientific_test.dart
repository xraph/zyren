// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:scientific_lab/main.dart';
import '../../../test/native_volume_test.dart' as volume_checks;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  volume_checks.main(native: true);
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
        if (!state.busy && state.stats != null) return;
      }
      fail('Native scientific view did not become ready.');
    }

    await ready();
    for (final mode in ScientificWorkbenchState.modes.keys) {
      final before = state.stats!.frameId;
      await tester.tap(find.byKey(ValueKey('mode-$mode')));
      await ready();
      for (var i = 0; i < 100 && state.stats!.frameId == before; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.selected, mode);
      expect(state.stats!.frameId, greaterThan(before));
      expect(state.stats!.readbackBytes, 0);
      expect(state.stats!.presentationPath, isNot(PresentationPath.readback));
      expect(tester.takeException(), isNull);
      if (mode == 'Temporal') {
        await state.seek(.5);
        await ready();
        expect(state.field!.time!.time, .5);
      }
      print(
        'SCIENTIFIC_PRESENTED mode=$mode path=${state.stats!.presentationPath.name} frame=${state.stats!.frameId} readback=${state.stats!.readbackBytes} size=${state.stats!.physicalSize.width}x${state.stats!.physicalSize.height}',
      );
    }
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
    await state.field!.configure(
      expectedRevision: state.field!.revision,
      threshold: 500,
    );
    state.viewport.invalidate();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No geometry at these settings'), findsOneWidget);
    await tester.tap(find.text('Show slice'));
    await ready();
    final actualSize = tester.view.physicalSize;
    for (final logicalWidth in [390.0, 1100.0]) {
      tester.view.physicalSize = Size(
        logicalWidth * tester.view.devicePixelRatio,
        720 * tester.view.devicePixelRatio,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(350));
    }
    tester.view.physicalSize = actualSize;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.field!.isDisposed, isTrue);
    print('SCIENTIFIC_FLUTTER_COMPLETE pick, commands, layouts and disposal');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
