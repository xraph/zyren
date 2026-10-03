import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/widgets.dart';
import 'package:zyren_xr_probe/main.dart';
import 'package:zyren_xr/zyren_xr.dart';
import '../../test/fixtures.dart';

void main() {
  testWidgets(
    'failed disposal clears stale UI and retains a working release retry',
    (tester) async {
      final transport = RecordingTransport();
      var disposalAttempts = 0;
      transport.handler = (method, arguments) {
        if (method == 'dispose' && ++disposalAttempts == 1) {
          throw const XrException('busy', 'Retirement needs a retry.');
        }
        return switch (method) {
          'create' => {'sessionId': 'session-1'},
          'capabilities' => capabilitiesMessage(),
          'snapshot' => snapshotMessage(),
          _ => null,
        };
      };
      await tester.pumpWidget(XrProbeApp(transport: transport));
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump();
      expect(find.text('running / normal'), findsOneWidget);
      await tester.tap(find.text('Release'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('running / normal'), findsNothing);
      expect(find.textContaining('Agent tools'), findsNothing);
      expect(find.textContaining('Retirement needs a retry.'), findsOneWidget);
      expect(disposalAttempts, 1);
      await tester.tap(find.text('Release'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(disposalAttempts, 2);
      expect(find.text('Session not started'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
