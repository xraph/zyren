import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multiple_views/android_surface_demo.dart';

void main() {
  testWidgets('closing the first surface preserves the second native session', (
    tester,
  ) async {
    var created = 0;
    final closed = <int>[];
    final rendered = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      androidProofChannel,
      (MethodCall call) async {
        final args = call.arguments as Map?;
        switch (call.method) {
          case 'create':
            final id = ++created;
            return {'session': id, 'texture': id};
          case 'close':
            closed.add(args!['session'] as int);
            return null;
          case 'suspend':
            return null;
          case 'render':
            rendered.add(args!['session'] as int);
            return {
              'applied': true,
              'presented': true,
              'adapter': 'fixture',
              'readbackBytes': 0,
            };
          default:
            throw StateError('Unexpected native call ${call.method}');
        }
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        androidProofChannel,
        null,
      );
    });
    await tester.pumpWidget(const MaterialApp(home: AndroidSurfaceDemo()));
    await tester.pump();
    expect(created, 2);
    await tester.tap(find.text('Close first'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      created,
      2,
      reason: 'The second renderer must survive removal of its sibling.',
    );
    expect(closed, [1]);
    expect(rendered, contains(2));
    await tester.tap(find.text('Resize'));
    await tester.pump();
    expect(created, 2);
    await tester.tap(find.text('Open first'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(created, 3);
    expect(closed, [1]);
    expect(rendered, containsAll([2, 3]));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(closed, containsAll([1, 2, 3]));
  });
}
