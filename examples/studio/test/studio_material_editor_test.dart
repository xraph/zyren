import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_material_editor.dart';

void main() {
  testWidgets('material editor validates colors and applies shading values', (
    tester,
  ) async {
    StudioMaterial? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: StudioMaterialEditor(
                value: StudioMaterial(
                  kind: StudioMaterialKind.standard,
                  metallic: .4,
                ),
                onApply: (v) => result = v,
              ),
            ),
          ),
        ),
      ),
    );
    final color = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Base color (hex)',
    );
    await tester.enterText(color, 'not-a-color');
    await tester.ensureVisible(find.text('Apply material'));
    await tester.tap(find.text('Apply material'));
    await tester.pump();
    expect(result, isNull);
    expect(find.text('Check color and material values.'), findsOneWidget);
    await tester.enterText(color, 'ff8040');
    await tester.tap(find.text('Apply material'));
    await tester.pump();
    expect(result!.color, 0xff8040);
    expect(result!.metallic, .4);
    expect(result!.kind, StudioMaterialKind.standard);
    expect(tester.takeException(), isNull);
  });
}
