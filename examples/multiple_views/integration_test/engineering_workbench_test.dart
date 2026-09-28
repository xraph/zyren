import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering/file_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/scene_workbench.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native engineering review saves and reloads onto a fresh scene', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/gpu3d-workbench',
    ).create(recursive: true);
    final temporary = await root.createTemp('integration-');
    addTearDown(() => temporary.delete(recursive: true));
    final store = FileEngineeringStore(File('${temporary.path}/review.json'));
    final runtime = Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal();
    SceneController? controller;
    final stats = <FrameStats>[];
    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        if (condition()) return;
        if (controller?.status.value case SceneFailed(:final issue)) {
          fail(issue.message);
        }
      }
      fail('Engineering workbench did not reach the expected state.');
    }

    Future<void> open() async {
      await tester.pumpWidget(
        SceneWorkbenchApp(runtime: runtime, reviewStore: store),
      );
      controller = tester.widget<SceneView>(find.byType(SceneView)).controller!;
      await until(
        () =>
            controller!.status.value is SceneReady &&
            tester
                    .widget<IconButton>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is IconButton &&
                            widget.tooltip == 'Save review',
                      ),
                    )
                    .onPressed !=
                null,
      );
    }

    Future<void> close() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
      await controller!.whenDisposed;
    }

    await open();
    final subscription = controller!.frameStats.listen(stats.add);
    final housing = controller!.scene.children.single.children.first;
    final cover = controller!.scene.children.single.children.firstWhere(
      (node) => node.name == 'Cover',
    );
    await tester.tap(find.byKey(const ValueKey('review-tab')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byTooltip('Edit metadata'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey('metadata-tag')),
      'NATIVE-P-204',
    );
    await tester.tap(find.text('Apply'));
    await until(() => find.text('tag: NATIVE-P-204').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('Isolate selected'));
    await until(() => !cover.visible);
    expect(housing.visible, isTrue);
    await tester.tap(find.byTooltip('Restore visibility'));
    await until(() => cover.visible);
    await tester.tap(find.byTooltip('Add surface note'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(tester.getCenter(find.byType(SceneView)));
    await until(
      () => find.byKey(const ValueKey('annotation-text')).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey('annotation-text')),
      'Check the seal face',
    );
    await tester.tap(find.text('Apply'));
    await until(
      () => housing.children.any((node) => node.name == 'Review pin'),
    );
    final anchor = housing.children
        .singleWhere((node) => node.name == 'Review pin')
        .position;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byTooltip('Save review'));
    await until(() => find.text('Saved').evaluate().isNotEmpty);
    final saved = EngineeringDocument.decode((await store.read())!);
    expect(saved.objects['housing']!.properties['tag'], 'NATIVE-P-204');
    expect(saved.annotations.values.single.text, 'Check the seal face');
    await tester.pump(const Duration(milliseconds: 250));
    controller!.invalidate();
    await until(() => stats.isNotEmpty && stats.last.drawCalls == 13);
    expect(stats.map((frame) => frame.readbackBytes), everyElement(0));
    await close();
    await subscription.cancel();
    await open();
    final freshHousing = controller!.scene.children.single.children.first;
    await until(
      () => freshHousing.children.any((node) => node.name == 'Review pin'),
    );
    expect(freshHousing, isNot(same(housing)));
    expect(
      freshHousing.children
          .singleWhere((node) => node.name == 'Review pin')
          .position,
      anchor,
    );
    await tester.tap(find.byKey(const ValueKey('review-tab')));
    await until(() => find.text('tag: NATIVE-P-204').evaluate().isNotEmpty);
    expect(find.text('Saved'), findsOneWidget);
    debugPrint(
      'Engineering native evidence: ${stats.length} samples, annotation pin rendered, zero readback bytes, application-support save and fresh-scene reload passed.',
    );
    await close();
    expect(tester.takeException(), isNull);
  });
}
