import 'package:flutter_test/flutter_test.dart';

Future<void> chooseExample(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Examples'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
