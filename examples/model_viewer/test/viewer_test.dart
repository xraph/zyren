import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:model_viewer/main.dart';
import '../../../packages/flutter_gpu3d/test/support/backend_fake.dart';
import '../../../packages/flutter_gpu3d/test/support/fakes.dart';

class Sources implements ByteSourceResolver {
  final data = File('assets/models/assembly.glb').readAsBytesSync();
  Completer<void>? gate;
  bool fail = false;
  int reads = 0, cancelled = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    final stopped = Completer<void>();
    final registration = context.cancellation.onCancel(() {
      cancelled++;
      stopped.complete();
    });
    try {
      context.reportProgress(12);
      if (gate != null) await Future.any([gate!.future, stopped.future]);
      context.cancellation.throwIfCancelled();
      if (fail) {
        throw AssetLoadException(
          AssetLoadError.sourceFailed,
          'Fixture unavailable',
        );
      }
      return ResolvedSource(
        effectiveUri: uri,
        bytes: uri.path.endsWith('pbr.glb') || uri.path.endsWith('colors.glb')
            ? File('assets/models/${uri.pathSegments.last}').readAsBytesSync()
            : data,
      );
    } finally {
      registration.dispose();
    }
  }
}

class Images implements ImageDecoder {
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async => ImageData(pixels: Uint8List(16), size: PhysicalSize(2, 2));
}

SceneRuntime runtime(Sources sources, FakeBackend backend) => SceneRuntime(
  assetServices: AssetServices(resolver: sources, imageDecoder: Images()),
  backendFactory: () async => backend,
  presenterFactory: () => TestPresenter('native frame', backend.events),
);
Future<void> waitForModel(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    final view = tester.widget<SceneView>(find.byType(SceneView));
    if (view.controller!.scene.children.isNotEmpty &&
        find.text('Cancel').evaluate().isEmpty) {
      return;
    }
  }
  fail('Model did not load.');
}

Future<void> remove(WidgetTester tester) async {
  final controller = tester
      .widget<SceneView>(find.byType(SceneView))
      .controller!;
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => controller.whenDisposed);
  await tester.pump();
}

void main() {
  testWidgets('PBR scenes use authored lights or an explicit studio toggle', (
    tester,
  ) async {
    final sources = Sources(), backend = FakeBackend();
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ModelViewerApp(
        runtime: runtime(sources, backend),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await waitForModel(tester);
    await tester.tap(find.text('PBR model'));
    await waitForModel(tester);
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    expect(controller.scene.children.single.name, 'PBR assembly');
    expect(find.byTooltip('Studio light'), findsNothing);
    expect(backend.submissions.last.scene.drawCalls, 3);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No authored lights').last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Studio light'), findsOneWidget);
    final studio = controller.scene.children.single.children.last;
    expect(studio.name, 'Viewer studio');
    expect(studio.visible, isTrue);
    await tester.tap(find.byTooltip('Studio light'));
    await tester.pump();
    expect(studio.visible, isFalse);
    for (final size in [const Size(320, 640), const Size(390, 700)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(240));
    }
    await tester.tap(find.text('Colors'));
    await waitForModel(tester);
    final root = controller.scene.children.single;
    expect(root.name, 'Vertex color assembly');
    final meshes = <Mesh>[];
    void collect(Object3D object) {
      if (object is Mesh) meshes.add(object);
      for (final child in object.children) {
        collect(child);
      }
    }

    collect(root);
    expect(meshes, hasLength(3));
    expect(
      meshes.every((m) => m.material.vertexColors && m.geometry.colors != null),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await remove(tester);
  });
  testWidgets(
    'bundle loading, named scenes and controls fit desktop and narrow layouts',
    (tester) async {
      final sources = Sources(), backend = FakeBackend();
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ModelViewerApp(
          runtime: runtime(sources, backend),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await waitForModel(tester);
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      expect(controller.scene.children.single.name, 'Assembly');
      expect(backend.submissions.last.scene.drawCalls, 3);
      final before = controller.camera.position;
      await tester.drag(find.byType(SceneView), const Offset(40, 20));
      await tester.pump();
      expect(controller.camera.position, isNot(before));
      await tester.tap(find.text('Objects'));
      await tester.pumpAndSettle();
      expect(find.text('Housing'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Single box').last);
      await tester.pumpAndSettle();
      expect(controller.scene.children.single.name, 'Single box');
      for (final size in [const Size(320, 640), const Size(390, 700)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SceneView)).height, greaterThan(270));
      }
      await tester.tap(find.byTooltip('Clear model'));
      await tester.pump();
      expect(controller.scene.children, isEmpty);
      expect(find.text('Load a 3D model'), findsOneWidget);
      await remove(tester);
      expect(backend.closeCount, 1);
    },
  );
  testWidgets(
    'unknown-length progress, cancellation, URI retry and route removal settle',
    (tester) async {
      final sources = Sources()..gate = Completer<void>();
      final backend = FakeBackend();
      await tester.pumpWidget(
        ModelViewerApp(
          runtime: runtime(sources, backend),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await tester.pump();
      expect(find.text('fetch · 12 bytes'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://models.test/assembly.glb',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Cancelled'), findsOneWidget);
      expect(sources.cancelled, 1);
      sources.gate!.complete();
      sources.gate = null;
      sources.fail = true;
      await tester.tap(find.byTooltip('Load URI'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fixture unavailable'), findsOneWidget);
      sources.fail = false;
      await tester.tap(find.text('Retry'));
      await waitForModel(tester);
      expect(sources.reads, 3);
      sources.gate = Completer<void>();
      await tester.tap(find.text('Relative glTF'));
      await tester.pump();
      await remove(tester);
      sources.gate!.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(sources.cancelled, 2);
      expect(backend.closeCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
