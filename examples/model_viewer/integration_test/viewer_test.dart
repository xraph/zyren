import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:model_viewer/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundle and HTTP glTF present natively and survive reloads', (
    tester,
  ) async {
    final requests = <String, int>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests.update(path, (n) => n + 1, ifAbsent: () => 1);
      if (!['/assembly.gltf', '/assembly.bin', '/corners.png'].contains(path)) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        final data = await rootBundle.load('assets/models$path');
        request.response.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      await request.response.close();
    });
    SceneController? controller;
    StreamSubscription<FrameStats>? subscription;
    final frames = <FrameStats>[];
    Future<void> ready() async {
      for (var i = 0; i < 250; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        if (controller!.status.value case SceneFailed(:final issue)) {
          fail(issue.message);
        }
        if (frames.isNotEmpty &&
            frames.last.drawCalls == 3 &&
            find.text('Cancel').evaluate().isEmpty) {
          return;
        }
      }
      fail(
        'Model did not produce a native frame: '
        'status=${controller!.status.value}, frames=${frames.length}, '
        'draws=${frames.isEmpty ? null : frames.last.drawCalls}, '
        'models=${controller.scene.children.map((node) => node.name).toList()}, '
        'requests=$requests.',
      );
    }

    Future<void> loadWith(Finder control) async {
      frames.clear();
      await tester.tap(control);
      await ready();
    }

    try {
      await tester.pumpWidget(
        ModelViewerApp(
          runtime: Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : const SceneRuntime.nativeMetal(),
        ),
      );
      controller = tester.widget<SceneView>(find.byType(SceneView)).controller!;
      subscription = controller.frameStats.listen(frames.add);
      await ready();
      expect(controller.scene.children.single.name, 'Assembly');
      expect(frames.last.readbackBytes, 0);
      final initialCamera = controller.camera.position;
      await tester.drag(find.byType(SceneView), const Offset(50, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.camera.position, isNot(initialCamera));
      await loadWith(find.text('Relative glTF'));
      expect(frames.last.readbackBytes, 0);
      await tester.enterText(
        find.byType(TextField),
        'http://127.0.0.1:${server.port}/assembly.gltf',
      );
      await loadWith(find.byTooltip('Load URI'));
      expect(requests, {
        '/assembly.gltf': 1,
        '/assembly.bin': 1,
        '/corners.png': 1,
      });
      expect(frames.last.readbackBytes, 0);
      for (var i = 0; i < 3; i++) {
        await loadWith(find.text('Retry'));
      }
      expect(requests['/assembly.gltf'], 4);
      await loadWith(find.text('PBR model'));
      expect(controller.scene.children.single.name, 'PBR assembly');
      expect(find.byTooltip('Studio light'), findsNothing);
      expect(frames.last.readbackBytes, 0);
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await loadWith(find.text('No authored lights').last);
      expect(find.byTooltip('Studio light'), findsOneWidget);
      final studio = controller.scene.children.single.children.last;
      expect(studio.visible, isTrue);
      await tester.tap(find.byTooltip('Studio light'));
      await tester.pump();
      expect(studio.visible, isFalse);

      await loadWith(find.text('Colors'));
      expect(controller.scene.children.single.name, 'Vertex color assembly');
      expect(frames.last.readbackBytes, 0);

      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller?.whenDisposed;
      await subscription?.cancel();
      await server.close(force: true);
    }
  });
}
