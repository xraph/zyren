import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/widgets.dart';
import 'package:zyren_xr_probe/main.dart';
import '../../test/fixtures.dart';

void main() {
  for (final width in [320.0, 1100.0]) {
    testWidgets('compact session states fit width $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final transport = RecordingTransport();
      await tester.pumpWidget(XrProbeApp(transport: transport));
      expect(find.byType(ZeroState), findsOneWidget);
      expect(find.text('Session not started'), findsOneWidget);
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      expect(find.text('running / normal'), findsOneWidget);
      expect(
        find.textContaining('Depth requested false / presented unknown'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Release'));
      await tester.pump();
      expect(find.text('Session not started'), findsOneWidget);
      expect(transport.calls.where((c) => c.$1 == 'dispose').length, 1);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
