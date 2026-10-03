import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'support/backend_fake.dart';
import 'scene_assets_test.dart' as assets show Resolver, runtime;
import 'package:flutter_zyren/src/input/flutter_input_adapter.dart';
import 'controller_test.dart' show host, frames, readback, runtime;

void main() {
  testWidgets(
    'ordered bubbling, stopping, current handlers and missed clicks',
    (tester) async {
      late SceneController controller;
      final calls = <String>[];
      var stop = false;
      Widget tree(String name) => host(
        SceneCanvas(
          options: readback,
          runtime: sceneRuntime,
          onCreated: (c) => controller = c,
          onPointerMissed: (_) => calls.add('missed'),
          children: [
            GroupNode(
              onClick: (_) => calls.add('parent'),
              children: [
                MeshNode(
                  geometry: SceneGeometry.box(),
                  onClick: (e) {
                    calls.add(name);
                    expect(e.intersections, isNotEmpty);
                    if (stop) e.stopPropagation();
                  },
                ),
                MeshNode(
                  position: const Vec3(0, 0, -2),
                  geometry: SceneGeometry.box(),
                  onClick: (_) => calls.add('far'),
                ),
              ],
            ),
          ],
        ),
      );
      sceneRuntime = runtime(FakeBackend());
      await tester.pumpWidget(tree('near'));
      await frames(tester);
      void emit(ViewportPoint p) =>
          (controller.input as FlutterInputAdapter).emit(
            ScenePointerEvent(point: p, phase: ScenePointerPhase.tap),
            null,
          );
      emit(const ViewportPoint(32, 32));
      await tester.pump();
      expect(calls, ['near', 'parent', 'far']);
      calls.clear();
      stop = true;
      await tester.pumpWidget(tree('new'));
      await tester.pump();
      emit(const ViewportPoint(32, 32));
      await tester.pump();
      expect(calls, ['new']);
      calls.clear();
      emit(const ViewportPoint(0, 0));
      await tester.pump();
      expect(calls, ['missed']);
      var navigationScrolls = 0;
      final navigation = InputRouter.forSource(controller.input).register(
        id: 'test-navigation',
        priority: InputPriority.navigation,
        claims: (_) => true,
        onEvent: (event) {
          if (event.phase == ScenePointerPhase.scroll) navigationScrolls++;
        },
      );
      (controller.input as FlutterInputAdapter).emit(
        ScenePointerEvent(
          point: const ViewportPoint(32, 32),
          phase: ScenePointerPhase.scroll,
        ),
        null,
      );
      await tester.pump();
      expect(navigationScrolls, 1);
      navigation.dispose();

      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );
  testWidgets(
    'capture delivers outside geometry and cancellation is pointer specific',
    (tester) async {
      late SceneController controller;
      final moves = <int>[], cancels = <int>[];
      await tester.pumpWidget(
        host(
          SceneCanvas(
            options: readback,
            runtime: runtime(FakeBackend()),
            onCreated: (c) => controller = c,
            children: [
              MeshNode(
                geometry: SceneGeometry.box(),
                onPointerDown: (e) => e.capturePointer(),
                onPointerMove: (e) {
                  moves.add(e.pointer);
                  expect(e.intersection, isNull);
                  expect(e.captureIntersection, isNotNull);
                },
                onPointerCancel: (e) => cancels.add(e.pointer),
              ),
            ],
          ),
        ),
      );
      await frames(tester);
      void emit(int pointer, ScenePointerPhase phase, ViewportPoint point) =>
          (controller.input as FlutterInputAdapter).emit(
            ScenePointerEvent(pointer: pointer, point: point, phase: phase),
            null,
          );
      for (final id in [1, 2]) {
        emit(id, ScenePointerPhase.down, const ViewportPoint(32, 32));
      }
      emit(1, ScenePointerPhase.cancel, const ViewportPoint(0, 0));
      emit(2, ScenePointerPhase.move, const ViewportPoint(0, 0));
      await tester.pump();
      expect(cancels, [1]);
      expect(moves, [2]);
      await tester.pumpWidget(const SizedBox());
      await frames(tester);
    },
  );
  testWidgets('hover leaves on canvas exit and unmount clears capture', (
    tester,
  ) async {
    late SceneController controller;
    final calls = <String>[];
    final rt = runtime(FakeBackend());
    Widget tree(bool show) => host(
      SceneCanvas(
        options: readback,
        runtime: rt,
        onCreated: (c) => controller = c,
        children: [
          if (show)
            MeshNode(
              geometry: SceneGeometry.box(),
              onPointerEnter: (_) => calls.add('enter'),
              onPointerLeave: (_) => calls.add('leave'),
              onPointerDown: (e) => e.capturePointer(),
              onPointerMove: (_) => calls.add('move'),
            ),
        ],
      ),
    );
    await tester.pumpWidget(tree(true));
    await frames(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byType(SceneView)));
    await tester.pump();
    await mouse.moveTo(
      tester.getCenter(find.byType(SceneView)) + const Offset(1, 0),
    );
    await tester.pump();
    final cursorInput = controller.input as FlutterInputAdapter;
    for (final phase in [
      ScenePointerPhase.down,
      ScenePointerPhase.move,
      ScenePointerPhase.up,
      ScenePointerPhase.hover,
    ]) {
      cursorInput.emit(
        ScenePointerEvent(
          pointer: phase == ScenePointerPhase.hover ? 0 : 27,
          kind: ScenePointerKind.mouse,
          point: const ViewportPoint(32, 32),
          phase: phase,
        ),
        null,
      );
    }
    await tester.pump();
    expect(calls.where((call) => call == 'enter').length, 1);
    calls.removeWhere((call) => call == 'move');
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(calls, ['enter', 'leave']);
    calls.clear();
    final input = controller.input as FlutterInputAdapter;
    input.emit(
      ScenePointerEvent(
        pointer: 1,
        point: const ViewportPoint(32, 32),
        phase: ScenePointerPhase.down,
      ),
      null,
    );
    await tester.pump();
    await tester.pumpWidget(tree(false));
    await tester.pump();
    input.emit(
      ScenePointerEvent(
        pointer: 1,
        point: const ViewportPoint(0, 0),
        phase: ScenePointerPhase.move,
      ),
      null,
    );
    await tester.pump();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
  testWidgets('loaded glTF mesh bubbles clicks to ModelNode', (tester) async {
    final positions = Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]);
    final data = base64Encode(positions.buffer.asUint8List());
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'asset': {'version': '2.0'},
          'scene': 0,
          'scenes': [
            {
              'nodes': [0],
            },
          ],
          'nodes': [
            {'mesh': 0},
          ],
          'buffers': [
            {
              'byteLength': 36,
              'uri': 'data:application/octet-stream;base64,$data',
            },
          ],
          'bufferViews': [
            {'buffer': 0, 'byteLength': 36},
          ],
          'accessors': [
            {
              'bufferView': 0,
              'componentType': 5126,
              'count': 3,
              'type': 'VEC3',
              'min': [-1, -1, 0],
              'max': [1, 1, 0],
            },
          ],
          'meshes': [
            {
              'primitives': [
                {
                  'attributes': {'POSITION': 0},
                },
              ],
            },
          ],
        }),
      ),
    );
    final ref = SceneRef<ModelInstance>();
    late SceneController controller;
    SceneObjectEvent? clicked;
    await tester.pumpWidget(
      host(
        SceneCanvas(
          options: readback,
          runtime: assets.runtime(
            AssetServices(resolver: assets.Resolver(bytes)),
          ),
          onCreated: (c) => controller = c,
          children: [
            ModelNode(
              ref: ref,
              request: Gltf.uri(Uri.parse('memory:/triangle.gltf')),
              onClick: (event) => clicked = event,
            ),
          ],
        ),
      ),
    );
    for (var attempt = 0; attempt < 100 && ref.current == null; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await frames(tester);
    expect(ref.current, isNotNull);
    (controller.input as FlutterInputAdapter).emit(
      ScenePointerEvent(
        point: const ViewportPoint(32, 32),
        phase: ScenePointerPhase.tap,
      ),
      null,
    );
    await tester.pump();
    expect(clicked, isNotNull);
    expect(clicked!.currentTarget, same(ref.require));
    expect(clicked!.hitObject, isA<Mesh>());
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
  });
}

late SceneRuntime sceneRuntime;
