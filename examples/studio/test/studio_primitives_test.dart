import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/streaming.dart';
import 'package:zyren_studio_example/studio_primitive_picker.dart';
import 'package:zyren_studio_example/studio_theme.dart';

void main() {
  for (final width in [328.0, 1200.0]) {
    testWidgets(
      'all primitive choices create saved meshes with undo at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scene = StudioScene(
          StudioDocument(id: 'shapes', title: 'Shapes', nodes: []),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: studioTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    final kind = await showStudioPrimitivePicker(context);
                    if (kind != null) {
                      scene.apply(
                        StudioModeling.addNodes(scene.capture(), [
                          StudioNode(
                            id: kind.name,
                            label: kind.name,
                            kind: kind,
                          ),
                        ]),
                      );
                    }
                  },
                  child: const Text('Add primitive'),
                ),
              ),
            ),
          ),
        );
        for (final kind in StudioNodeKind.values.where((k) => k.isPrimitive)) {
          await tester.tap(find.text('Add primitive'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text('${kind.name[0].toUpperCase()}${kind.name.substring(1)}'),
          );
          await tester.pumpAndSettle();
          expect(scene.objects.containsKey(kind.name), isTrue);
          expect(scene.undo(), isTrue);
          expect(scene.objects.containsKey(kind.name), isFalse);
          expect(scene.redo(), isTrue);
        }
        final source = scene.capture(),
            package = ZyrenScenePackage.compile(scene.capture());
        final stream = await ZyrenSceneStream.open(
          Uri.parse('asset:/shapes.zyren'),
          read: (uri, _, _) async => uri.path.endsWith('.zyren')
              ? package.manifest
              : package.files[uri.path.substring(1)]!,
        );
        await stream.loadAll();
        expect((await stream.readDocument()).encode(), source.encode());
        expect(
          (jsonDecode(utf8.decode(package.manifest))['chunks'] as List).length,
          6,
        );
        await stream.close();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
