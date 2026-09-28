import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d_inspector/gpu3d_inspector.dart';

class CountedValue<T> extends ValueNotifier<T> {
  int listeners = 0;
  CountedValue(super.value);
  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

class CountedScene extends Scene {
  int listeners = 0;
  @override
  Stream<int> get changes => Stream.multi((events) {
    listeners++;
    final subscription = super.changes.listen(events.addSync);
    events.onCancel = () {
      listeners--;
      return subscription.cancel();
    };
  });
}

class InspectableController extends SceneController {
  final state = CountedValue<SceneStatus>(const SceneDetached(0));
  final frames = StreamController<FrameStats>.broadcast(sync: true);
  final errors = StreamController<SceneIssue>.broadcast(sync: true);
  int frameListeners = 0, issueListeners = 0;
  FrameStats? latest;
  InspectableController({super.scene});
  @override
  CountedValue<SceneStatus> get status => state;
  @override
  FrameStats? get latestFrameStats => latest;
  @override
  Stream<FrameStats> get frameStats => Stream.multi((events) {
    frameListeners++;
    final sub = frames.stream.listen(events.addSync);
    events.onCancel = () {
      frameListeners--;
      return sub.cancel();
    };
  });
  @override
  Stream<SceneIssue> get issues => Stream.multi((events) {
    issueListeners++;
    final sub = errors.stream.listen(events.addSync);
    events.onCancel = () {
      issueListeners--;
      return sub.cancel();
    };
  });
  void publish(int id, {int? residentBytes, Duration? gpuTime}) {
    latest = FrameStats(
      frameId: id,
      physicalSize: PhysicalSize(640, 480),
      presentationPath: PresentationPath.nativeView,
      cpuBuildTime: const Duration(microseconds: 100),
      cpuSubmitTime: const Duration(microseconds: 200),
      drawCalls: id,
      triangles: id * 12,
      readbackBytes: 0,
      uploadedBytes: 128,
      residentBytes: residentBytes,
      gpuTime: gpuTime,
    );
    frames.add(latest!);
  }

  Future<void> close() async {
    super.dispose();
    await whenDisposed;
    await frames.close();
    await errors.close();
    state.dispose();
  }
}

Widget host(Widget child, {double width = 360, double height = 600}) =>
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

void main() {
  testWidgets(
    'late overlay shows the last frame, throttles and passes hits through',
    (tester) async {
      final controller = InspectableController()..publish(1);
      var taps = 0;
      await tester.pumpWidget(
        host(
          Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => taps++,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              SceneStatsOverlay(controller: controller),
            ],
          ),
        ),
      );
      expect(find.textContaining('1 draws'), findsOneWidget);
      expect(find.textContaining('GPU unavailable'), findsOneWidget);
      expect(find.textContaining('Resident unavailable'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(SceneStatsOverlay)));
      expect(taps, 1);
      controller.publish(2);
      controller.publish(
        3,
        residentBytes: 1024,
        gpuTime: const Duration(microseconds: 900),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('1 draws'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('3 draws'), findsOneWidget);
      expect(find.textContaining('Resident 1.0 KiB'), findsOneWidget);
      expect(find.textContaining('GPU 0.90 ms'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(controller.frameListeners, 0);
      expect(controller.state.listeners, 0);
      expect(controller.isDisposed, isFalse);
      await controller.close();
    },
  );

  testWidgets(
    'tree search, selection, mutations and empty states stay read-only',
    (tester) async {
      final scene = CountedScene();
      final group = scene.add(Group(name: 'Assembly'));
      final mesh = group.add(
        Mesh(BoxGeometry(), DiffuseMaterial(), name: 'Rotor'),
      );
      scene.add(Group(name: 'Unrelated'));
      final controller = InspectableController(scene: scene);
      final originalListeners = scene.listeners;
      Object3D? chosen;
      await tester.pumpWidget(
        host(
          SceneInspector(
            controller: controller,
            onSelectionChanged: (value) => chosen = value,
          ),
        ),
      );
      expect(scene.listeners, originalListeners + 1);
      await tester.tap(find.byTooltip('Collapse Assembly'));
      await tester.pump();
      expect(find.text('Rotor'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Rotor');
      await tester.pump();
      expect(find.text('Assembly'), findsOneWidget);
      final rotorRow = find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Rotor'),
      );
      expect(rotorRow, findsOneWidget);
      expect(find.text('Unrelated'), findsNothing);
      final revision = scene.revision;
      await tester.tap(rotorRow);
      await tester.pump();
      expect(chosen, same(mesh));
      expect(scene.revision, revision);
      expect(find.textContaining('Position 0, 0, 0'), findsOneWidget);
      mesh.position = const Vec3(2, 3, 4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('Position 2, 3, 4'), findsOneWidget);
      group.remove(mesh);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('No matching objects'), findsOneWidget);
      expect(find.textContaining('Position 2, 3, 4'), findsNothing);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      scene.remove(group);
      scene.remove(scene.children.single);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('No scene objects'), findsOneWidget);
      expect(find.byType(ZeroState), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(controller.frameListeners, 0);
      expect(controller.issueListeners, 0);
      expect(controller.state.listeners, 0);
      expect(scene.listeners, originalListeners);
      expect(controller.isDisposed, isFalse);
      await controller.close();
    },
  );

  testWidgets(
    'unmount cancels pending samples and scene refresh without owning the scene',
    (tester) async {
      final scene = CountedScene();
      final controller = InspectableController(scene: scene)..publish(1);
      final originalListeners = scene.listeners;
      await tester.pumpWidget(host(SceneInspector(controller: controller)));
      controller.publish(2);
      scene.add(Group(name: 'Pending change'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      expect(scene.listeners, originalListeners);
      expect(controller.frameListeners, 0);
      expect(controller.issueListeners, 0);
      expect(controller.state.listeners, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(controller.isDisposed, isFalse);
      expect(scene.children.single.name, 'Pending change');
      await controller.close();
      expect(scene.listeners, 0);
    },
  );

  testWidgets(
    'controller replacement clears selection, issues and pending samples',
    (tester) async {
      final a = InspectableController()..publish(17);
      final b = InspectableController()..publish(29);
      final selected = a.scene.add(Group(name: 'Old object'));
      await tester.pumpWidget(
        host(SceneInspector(controller: a, selectedObject: selected)),
      );
      a.errors.add(
        SceneIssue(code: 'example', message: 'Old warning', operation: 'test'),
      );
      a.publish(18);
      await tester.pump();
      expect(find.textContaining('Old warning'), findsOneWidget);
      await tester.pumpWidget(host(SceneInspector(controller: b)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Old warning'), findsNothing);
      expect(find.text('Old object'), findsNothing);
      expect(find.textContaining('29 draws'), findsOneWidget);
      expect(a.frameListeners, 0);
      expect(a.issueListeners, 0);
      expect(a.state.listeners, 0);
      await tester.pumpWidget(const SizedBox());
      await a.close();
      await b.close();
    },
  );

  testWidgets(
    'failure and unavailable frame remain distinct at narrow and desktop sizes',
    (tester) async {
      final controller = InspectableController();
      final issue = SceneIssue(
        code: 'deviceLost',
        message: 'Device disconnected',
        operation: 'render',
      );
      for (final width in [320.0, 1000.0]) {
        await tester.binding.setSurfaceSize(Size(width, 700));
        await tester.pumpWidget(
          host(SceneInspector(controller: controller), width: width),
        );
        expect(find.textContaining('No presented frame'), findsOneWidget);
        expect(tester.takeException(), isNull);
        controller.state.value = SceneFailed(0, issue);
        await tester.pump();
        expect(find.textContaining('Device disconnected'), findsOneWidget);
        expect(find.text('Failed'), findsOneWidget);
        expect(tester.takeException(), isNull);
        controller.state.value = const SceneSuspended(0);
        await tester.pump();
        expect(find.text('Suspended'), findsOneWidget);
        controller.state.value = const SceneDetached(0);
      }
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      await tester.binding.setSurfaceSize(null);
    },
  );
}
