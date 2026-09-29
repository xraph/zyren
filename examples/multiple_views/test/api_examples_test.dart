import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:multiple_views/managed_mesh.dart';
import 'package:multiple_views/borrowed_viewer.dart';
import 'package:multiple_views/main.dart';
import 'package:multiple_views/textured_scene_demo.dart';
import 'package:multiple_views/material_alpha_demo.dart';
import 'package:multiple_views/primitives_demo.dart';
import 'package:multiple_views/material_side_demo.dart';
import '../../../packages/flutter_zyren/test/support/backend_fake.dart';
import '../../../packages/flutter_zyren/test/support/fakes.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Widget host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 100, height: 100, child: child)),
);
SceneRuntime runtime(FakeBackend backend) => SceneRuntime(
  backendFactory: () async => backend,
  presenterFactory: () => TestPresenter('frame', backend.events),
);

class TestImageDecoder implements ImageDecoder {
  Completer<ImageData> next = Completer<ImageData>();
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) => next.future;
}

void main() {
  testWidgets('material side controls retain a usable narrow canvas', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 640));
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialSideApp(
        runtime: runtime(backend),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await frames(tester);
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final group = controller.scene.children.single;
    final mesh = group.children.single as Mesh;
    expect(mesh.material.side, MaterialSide.front);
    await tester.tap(find.text('Back'));
    await frames(tester);
    expect(mesh.material.side, MaterialSide.back);
    await tester.tap(find.text('View back'));
    await tester.tap(find.text('Mirror'));
    await tester.tap(find.text('Unlit'));
    await frames(tester);
    expect(controller.camera.position.z, -5);
    expect(group.scale.x, -1);
    expect(mesh.material, isA<UnlitMaterial>());
    expect(mesh.material.side, MaterialSide.back);
    await tester.tap(find.text('Both'));
    await frames(tester);
    expect(mesh.material.side, MaterialSide.doubleSided);
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(350));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
    expect(backend.closeCount, 1);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'primitive sizing controls preserve resources and fit a narrow canvas',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = FakeBackend();
      await tester.pumpWidget(
        PrimitivesApp(
          runtime: runtime(backend),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await frames(tester);
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final line = controller.scene.children.whereType<Line>().single;
      final points = controller.scene.children.whereType<Points>().single;
      final geometry = line.geometry;
      await tester.tap(find.text('World'));
      await tester.tap(find.text('Circles'));
      await tester.tap(find.text('Move away'));
      await frames(tester);
      expect(line.material.widthUnits, SizeUnits.world);
      expect(points.material.shape, PointShape.square);
      expect(controller.camera.position, const Vec3(6, 4, 10));
      expect(line.geometry, same(geometry));
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await frames(tester);
      await tester.tap(find.text('Pixels'));
      await tester.drag(find.byType(Slider), const Offset(25, 0));
      await frames(tester);
      expect(line.material.widthUnits, SizeUnits.pixels);
      expect(line.material.width, greaterThan(6));
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await controller.whenDisposed;
      expect(backend.closeCount, 1);
    },
  );
  testWidgets('material controls redraw and retain a useful narrow canvas', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialAlphaApp(
        runtime: runtime(backend),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await frames(tester);
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final front = controller.scene.children.first as Mesh;
    expect(front.material.alphaMode, MaterialAlphaMode.blend);
    await tester.tap(find.text('Mask'));
    await frames(tester);
    expect(front.material.alphaMode, MaterialAlphaMode.mask);
    expect(front.material.writesDepth, isTrue);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await frames(tester);
    await tester.tap(find.text('Blend'));
    await tester.tap(find.text('Depth order'));
    await frames(tester);
    expect(front.renderOrder, -1);
    expect(front.material.writesDepth, isFalse);
    await tester.tap(find.text('Auto depth'));
    await tester.drag(find.byType(Slider), const Offset(-30, 0));
    await frames(tester);
    expect(front.material.writesDepth, isTrue);
    expect(front.material.opacity, lessThan(.65));
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(300));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
    expect(backend.closeCount, 1);
  });
  testWidgets('geometry controls redraw on demand and fit narrow screens', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = FakeBackend();
    await tester.pumpWidget(
      TexturedSceneApp(
        runtime: runtime(backend),
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    await frames(tester);
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final mesh = controller.scene.children.single as Mesh;
    final geometry = mesh.geometry;
    final original = geometry.capture();
    final count = backend.submissions.length;
    await tester.tap(find.text('Deform'));
    await frames(tester);
    expect(geometry.revision, 1);
    expect(geometry.positions[6], closeTo(.4, 1e-6));
    expect(original.positions[6], 1);
    expect(backend.submissions.length, greaterThan(count));
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await frames(tester);
    await tester.tap(find.text('Shift UV'));
    await frames(tester);
    expect(geometry.revision, 2);
    expect(geometry.uv0![0], .25);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(SceneView)).height, greaterThan(300));
    await tester.tap(find.text('Reset'));
    await frames(tester);
    expect(mesh.geometry, same(geometry));
    expect(geometry.positions, original.positions);
    expect(geometry.uv0, original.uv0);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('image demo keeps its texture on decode failure and retries', (
    tester,
  ) async {
    final backend = FakeBackend();
    final decoder = TestImageDecoder();
    await tester.pumpWidget(
      TexturedSceneApp(
        runtime: runtime(backend),
        presentation: PresentationPolicy.readbackOnly,
        decoder: decoder,
      ),
    );
    await frames(tester);
    final controller = tester
        .widget<SceneView>(find.byType(SceneView))
        .controller!;
    final mesh = controller.scene.children.single as Mesh;
    final original = mesh.material.colorMap!.image;
    await tester.tap(find.text('PNG'));
    await frames(tester);
    expect(find.text('Decoding PNG…'), findsOneWidget);
    decoder.next.completeError(
      const ImageDecodeException(ImageDecodeError.invalidData, 'Test failure'),
    );
    await frames(tester);
    expect(find.textContaining('Tap PNG to retry'), findsOneWidget);
    expect(mesh.material.colorMap!.image, same(original));
    decoder.next = Completer<ImageData>();
    await tester.tap(find.text('PNG'));
    await frames(tester);
    decoder.next.complete(
      ImageData(
        pixels: Uint8List.fromList([255, 0, 0, 255]),
        size: PhysicalSize(1, 1),
      ),
    );
    await frames(tester);
    expect(find.textContaining('PNG 1×1'), findsOneWidget);
    expect(mesh.material.colorMap!.image, isNot(same(original)));
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controller.whenDisposed;
  });
  testWidgets(
    'texture controls retain image identity at desktop and narrow widths',
    (tester) async {
      final backend = FakeBackend();
      await tester.pumpWidget(
        TexturedSceneApp(
          runtime: runtime(backend),
          presentation: PresentationPolicy.readbackOnly,
        ),
      );
      await frames(tester);
      final controller = tester
          .widget<SceneView>(find.byType(SceneView))
          .controller!;
      final mesh = controller.scene.children.single as Mesh;
      final image = mesh.material.colorMap!.image;
      await tester.tap(find.text('Linear'));
      await frames(tester);
      expect(mesh.material.colorMap!.sampler.magFilter, TextureFilter.linear);
      expect(mesh.material.colorMap!.image, same(image));
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await frames(tester);
      await tester.tap(find.text('Mirror'));
      await frames(tester);
      expect(mesh.material.colorMap!.sampler.wrapU, TextureWrap.mirroredRepeat);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SceneView)).height, greaterThan(320));
      expect(mesh.material.colorMap!.image.generatesMipmaps, isTrue);
      await tester.tap(find.text('Dense UV'));
      await frames(tester);
      expect(mesh.geometry.uv0![1], 256);
      await tester.tap(find.text('Mips on'));
      await frames(tester);
      expect(mesh.material.colorMap!.image.generatesMipmaps, isFalse);
      expect(mesh.material.colorMap!.image.levels.single, image.levels.single);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      await controller.whenDisposed;
      expect(backend.closeCount, 1);
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'managed example owns one session through rebuilds and teardown',
    (tester) async {
      final backend = FakeBackend();
      final environment = runtime(backend);
      await tester.pumpWidget(host(ManagedMesh(runtime: environment)));
      await frames(tester);
      expect(backend.submissions.last.scene.drawCalls, 1);
      for (var i = 0; i < 4; i++) {
        await tester.pumpWidget(host(ManagedMesh(runtime: environment)));
      }
      expect(backend.closeCount, 0);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
      expect(backend.closeCount, 1);
    },
  );
  testWidgets('borrowed example survives unmount and reattaches', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = SceneController(
      runtime: runtime(backend),
      options: const EngineOptions(
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    await tester.pumpWidget(host(BorrowedViewer(controller: controller)));
    await frames(tester);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(backend.closeCount, 0);
    await tester.pumpWidget(host(BorrowedViewer(controller: controller)));
    await frames(tester);
    expect(backend.submissions.length, greaterThan(1));
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
    await tester.pumpWidget(const SizedBox());
    expect(backend.closeCount, 1);
  });
  testWidgets('shared scene keeps cameras and renderer ownership independent', (
    tester,
  ) async {
    final backends = <FakeBackend>[];
    await tester.pumpWidget(
      MultipleViewsApp(
        runtime: SceneRuntime(
          backendFactory: () async {
            final backend = FakeBackend();
            backends.add(backend);
            return backend;
          },
          presenterFactory: () => TestPresenter('frame', []),
        ),
      ),
    );
    await frames(tester);
    expect(backends, hasLength(2));
    final controllers = tester
        .widgetList<SceneView>(find.byType(SceneView))
        .map((w) => w.controller!)
        .toList();
    expect(controllers.first.scene, same(controllers.last.scene));
    expect(controllers.first.camera, isNot(same(controllers.last.camera)));
    final rightPosition = controllers.last.camera.position;
    final rightFrames = backends.last.submissions.length;
    await tester.tap(find.text('Move left camera'));
    await frames(tester);
    expect(controllers.last.camera.position, rightPosition);
    expect(backends.last.submissions.length, rightFrames);
    await tester.tap(find.text('Close left view'));
    await frames(tester);
    await controllers.first.whenDisposed;
    expect(backends.first.closeCount, 1);
    expect(backends.last.closeCount, 0);
    final remainingFrames = backends.last.submissions.length;
    await tester.tap(find.text('Turn mesh'));
    await frames(tester);
    expect(backends.last.submissions.length, greaterThan(remainingFrames));
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await frames(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await controllers.last.whenDisposed;
    expect(backends.last.closeCount, 1);
    await tester.binding.setSurfaceSize(null);
  });
}
