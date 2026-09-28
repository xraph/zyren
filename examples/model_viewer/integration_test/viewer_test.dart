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
      fail('Model did not produce a native frame.');
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
      frames.clear();
      await tester.tap(find.text('Relative glTF'));
      await ready();
      expect(frames.last.readbackBytes, 0);
      await tester.enterText(
        find.byType(TextField),
        'http://127.0.0.1:${server.port}/assembly.gltf',
      );
      frames.clear();
      await tester.tap(find.byTooltip('Load URI'));
      await ready();
      expect(requests, {
        '/assembly.gltf': 1,
        '/assembly.bin': 1,
        '/corners.png': 1,
      });
      expect(frames.last.readbackBytes, 0);
      for (var i = 0; i < 3; i++) {
        frames.clear();
        await tester.tap(find.text('Retry'));
        await ready();
      }
      expect(requests['/assembly.gltf'], 4);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await controller?.whenDisposed;
      await subscription?.cancel();
      await server.close(force: true);
    }
  });
}
