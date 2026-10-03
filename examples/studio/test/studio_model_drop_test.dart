import 'dart:async';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio_example/studio_model_drop.dart';

void main() {
  testWidgets(
    'drop holds file access until import finishes and releases on error',
    (tester) async {
      final calls = <String>[];
      final imported = <String>[];
      final errors = <String>[];
      final done = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('desktop_drop'),
        (call) async {
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StudioModelDrop(
            enabled: true,
            onError: errors.add,
            onFiles: (paths) async {
              imported.addAll(paths);
              await done.future;
              throw StateError('invalid mesh');
            },
            child: const SizedBox.expand(),
          ),
        ),
      );
      final drop = tester.widget<DropTarget>(find.byType(DropTarget));
      drop.onDragDone!(
        DropDoneDetails(
          files: [
            DropItemFile(
              '/model.glb',
              extraAppleBookmark: Uint8List.fromList([1, 2]),
            ),
          ],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(imported, ['/model.glb']);
      expect(calls, contains('startAccessingSecurityScopedResource'));
      expect(calls, isNot(contains('stopAccessingSecurityScopedResource')));
      done.complete();
      await tester.pump();
      expect(errors.single, contains('invalid mesh'));
      expect(calls.last, 'stopAccessingSecurityScopedResource');
      expect(tester.takeException(), isNull);
    },
  );
}
