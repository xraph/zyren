import 'dart:async';
import 'package:zyren_game_lab/game_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart' show ZeroState;
import 'package:zyren_game_lab/main.dart';

void main() {
  testWidgets(
    'load failure retries and stale completion closes after teardown',
    (tester) async {
      var attempts = 0;
      final pending = Completer<GameLabRun>();
      final run = _Run();
      await tester.pumpWidget(
        GameLabApp(
          loadGame: (_) {
            if (++attempts == 1) {
              return Future.error(StateError('load unavailable'));
            }
            return pending.future;
          },
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Play'));
      await tester.pumpAndSettle();
      expect(find.textContaining('load unavailable'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(attempts, 2);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      pending.complete(run);
      await tester.pumpAndSettle();
      expect(run.closes, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'screen disposal reports cleanup failure after releasing the run',
    (tester) async {
      final run = _Run(failClose: true);
      await tester.pumpWidget(GameLabApp(loadGame: (_) async => run));
      await tester.tap(find.widgetWithText(FilledButton, 'Play'));
      await tester.pumpAndSettle();
      expect(find.textContaining('render unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(run.closes, 1);
      expect(tester.takeException(), isA<StateError>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reference game selection remains usable at desktop and narrow text scale',
    (tester) async {
      try {
        for (final width in [1200.0, 396.0, 328.0]) {
          tester.view.physicalSize = Size(width, 760);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          await tester.pumpWidget(const GameLabApp());
          await tester.pumpAndSettle();
          expect(find.byType(ZeroState), findsOneWidget);
          expect(find.text('Choose a reference game'), findsOneWidget);
          expect(find.widgetWithText(FilledButton, 'Play'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Vehicle playground').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.reset();
      }
    },
  );
}

class _Run extends GameLabRun {
  final bool failClose;
  int closes = 0;
  _Run({this.failClose = false});
  @override
  Object get error => StateError('render unavailable');
  @override
  Future<void> close() async {
    closes++;
    dispose();
    if (failClose) throw StateError('cleanup failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
