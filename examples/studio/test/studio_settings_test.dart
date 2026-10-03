import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_settings.dart';
import 'package:zyren_studio_example/studio_theme.dart';

void main() {
  for (final width in [328.0, 1200.0]) {
    testWidgets('settings validate camera values and fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      StudioViewSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showStudioSettings(
                    context,
                    current: StudioViewSettings(
                      environment: StudioEnvironment(),
                      fieldOfView: 1,
                      near: .1,
                      far: 1000,
                      handleSize: 80,
                      grid: true,
                      fitHandles: true,
                      snap: false,
                      worldSpace: false,
                    ),
                    theme: ThemeMode.light,
                    onAgentSettings: () {},
                  );
                },
                child: const Text('Settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final near = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Near clip',
      );
      await tester.ensureVisible(near);
      await tester.enterText(near, '-1');
      await tester.tap(find.text('Apply settings'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.ensureVisible(near);
      await tester.enterText(near, '.2');
      await tester.tap(find.text('Apply settings'));
      await tester.pumpAndSettle();
      expect(result!.near, .2);
      expect(result!.fitHandles, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
