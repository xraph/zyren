import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openLabControls(WidgetTester tester) async {
  if (find.byKey(const ValueKey('controls-panel')).evaluate().isEmpty) {
    await tester.tap(find.byKey(const ValueKey('controls-toggle')));
    await tester.pumpAndSettle();
  }
}

Future<void> tapLabControl(WidgetTester tester, Finder control) async {
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
  await tester.tap(control);
  await tester.pumpAndSettle();
}
