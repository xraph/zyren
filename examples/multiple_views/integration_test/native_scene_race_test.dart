import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d_native/surfaces.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gpu3d/scene-views');
  Future<Map<Object?, Object?>> counters() async =>
      (await channel.invokeMapMethod<Object?, Object?>('diagnostics'))!;
  Future<void> arm(String phase) async {
    await channel.invokeMethod<void>('connect', {
      'runtime': NativeSurfaces().runtimeToken,
    });
    await channel.invokeMethod<void>('debugArm', {'phase': phase});
    addTearDown(() => channel.invokeMethod<void>('debugRelease'));
  }

  Future<Map<Object?, Object?>> waitForGate(WidgetTester tester) async {
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final gate = (await channel.invokeMapMethod<Object?, Object?>(
        'debugState',
      ))!;
      if (gate['entered'] == true) return gate;
    }
    fail('The native race gate was not reached.');
  }

  Future<void> baseline(WidgetTester tester) async {
    for (var i = 0; i < 100; i++) {
      final value = await counters();
      if ([
        'sessions',
        'renderers',
        'retiring',
        'heldDrawables',
      ].every((key) => value[key] == 0)) {
        return;
      }
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('Native ownership did not return to baseline: ${await counters()}');
  }

  Widget host(SceneController controller) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: 127,
        height: 93,
        child: SceneView(controller: controller),
      ),
    ),
  );
  SceneController controller() =>
      SceneController(runtime: const SceneRuntime.nativeMetal())
        ..scene.add(Mesh(BoxGeometry(), UnlitMaterial()));

  Future<void> closeDuringCreation(WidgetTester tester) async {
    await arm('create');
    final creating = const SceneRuntime.nativeMetal().backendFactory();
    final creationResult = expectLater(
      creating,
      throwsA(isA<SceneException>()),
    );
    final gate = await waitForGate(tester);
    var closed = false;
    final closing = channel
        .invokeMethod<void>('close', {'session': gate['session']})
        .then((_) => closed = true);
    await tester.pump(const Duration(milliseconds: 40));
    expect(closed, isFalse);
    expect((await counters())['sessions'], 1);
    expect((await counters())['renderers'], 1);
    await channel.invokeMethod<void>('debugRelease');
    await creationResult;
    await closing;
    await baseline(tester);
  }

  Future<void> disposeBeforeAttachment(WidgetTester tester) async {
    await arm('attach');
    final scene = controller();
    await tester.pumpWidget(host(scene));
    await waitForGate(tester);
    final before = await counters();
    scene.dispose();
    await tester.pumpWidget(const SizedBox());
    await scene.whenDisposed;
    await baseline(tester);
    await channel.invokeMethod<void>('debugRelease');
    await tester.pump(const Duration(milliseconds: 40));
    expect((await counters())['presented'], before['presented']);
    await baseline(tester);
  }

  Future<void> remountBeforeAttachment(WidgetTester tester) async {
    await arm('attach');
    final scene = controller();
    await tester.pumpWidget(host(scene));
    await waitForGate(tester);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(scene.isDisposed, isFalse);
    expect((await counters())['renderers'], 1);
    await channel.invokeMethod<void>('debugRelease');
    await tester.pumpWidget(host(scene));
    var presented = false;
    scene.firstFrame.then((_) => presented = true);
    for (var i = 0; i < 200 && !presented; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(scene.status.value, isA<SceneReady>());
    expect(presented, isTrue);
    scene.dispose();
    await tester.pumpWidget(const SizedBox());
    await scene.whenDisposed;
    await baseline(tester);
  }

  Future<void> disposeDuringCompletion(WidgetTester tester) async {
    await arm('render');
    final scene = controller();
    await tester.pumpWidget(host(scene));
    await waitForGate(tester);
    final before = await counters();
    expect(before['heldDrawables'], 1);
    var closed = false;
    scene.whenDisposed.then((_) => closed = true);
    scene.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 40));
    expect(closed, isFalse);
    expect((await counters())['heldDrawables'], 1);
    await channel.invokeMethod<void>('debugRelease');
    await scene.whenDisposed;
    await baseline(tester);
    final after = await counters();
    expect(after['presented'], before['presented']);
    expect(after['readbackBytes'], 0);
  }

  // Native frame callbacks belong to this engine's first test error zone.
  // Keep delayed error completions and their observers in the same zone.
  testWidgets(
    'native creation, attachment, remount and completion cancellation',
    (tester) async {
      await closeDuringCreation(tester);
      debugPrint('Native race verified: close during creation');
      await disposeBeforeAttachment(tester);
      debugPrint('Native race verified: dispose before attachment');
      await remountBeforeAttachment(tester);
      debugPrint('Native race verified: remount before attachment');
      await disposeDuringCompletion(tester);
      debugPrint('Native race verified: dispose during completion');
    },
  );
}
