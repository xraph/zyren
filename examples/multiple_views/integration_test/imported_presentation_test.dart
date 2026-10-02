import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../../packages/zyren_gltf/test/support/animated_fixture.dart';

final class _Source implements ByteSourceResolver {
  final Uint8List bytes;
  _Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

final class _Frames extends ScenePlugin {
  @override
  String get id => 'qualification.imported.frames';
  final frames = <FrameStats>[];
  VoidCallback? onFrame;
  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    frames.add(stats);
    onFrame?.call();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'imported animation presents, resizes and releases native surfaces',
    (tester) async {
      expect(Platform.isAndroid || Platform.isMacOS || Platform.isIOS, isTrue);
      final android = Platform.isAndroid;
      final channel = MethodChannel(
        android ? 'zyren/android-surfaces' : 'zyren/scene-views',
      );
      Future<Map> diagnostics() async =>
          (await channel.invokeMapMethod('diagnostics'))!;
      await channel.invokeMethod<void>('connect', {
        'runtime': NativeSurfaces().runtimeToken,
      });
      final baseline = await diagnostics();
      final assets = AssetScope(
        services: AssetServices(resolver: _Source(animatedModel())),
      );
      addTearDown(assets.close);
      final model = await assets.load(Gltf.asset('animated.glb')).result;
      final instance = model.instantiate();
      final sibling = model.instantiate()..position = const Vec3(0, 2.5, 0);
      final mesh = instance.nodes[0]!.children.single as Mesh;
      final siblingMesh = sibling.nodes[0]!.children.single as Mesh;
      final siblingGeometry = siblingMesh.geometry.capture();
      final controller = SceneController(
        scene: Scene()
          ..add(instance)
          ..add(sibling),
        camera: PerspectiveCamera(
          position: const Vec3(3, 0, 12),
          target: const Vec3(3, 0, 0),
        ),
        runtime: android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
      final timeline = controller.use(
        modelTimeline(instance, model.animations.single, loop: true),
      );
      final recorder = controller.use(_Frames());
      final frames = recorder.frames;
      final events = <TimelineEvent>[];
      final eventSubscription = timeline.events.listen(events.add);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
        await eventSubscription.cancel();
      });
      Widget view(double width, double height) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: SceneView(
              key: const ValueKey('imported-scene'),
              controller: controller,
            ),
          ),
        ),
      );
      Future<void> until(bool Function() ready, String phase) async {
        for (var i = 0; i < 1200; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          expect(tester.takeException(), isNull);
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(issue.message);
          }
          if (ready()) return;
        }
        fail('Imported presentation did not finish $phase.');
      }

      await tester.pumpWidget(view(420, 280));
      await until(
        () => controller.status.value is SceneReady && frames.isNotEmpty,
        'initialization',
      );
      final info = await controller.ready;
      final path = android
          ? PresentationPath.sharedTexture
          : PresentationPath.nativeView;
      expect(info.backend, android ? 'Vulkan' : 'Metal');
      expect(info.presentationPath, path);
      final wideSize = frames.last.physicalSize;
      final rest = timeline.createAction(modelRestClip(instance), weight: 1);
      final moving = timeline.createAction(
        modelClip(instance, model.animations.single),
        loop: true,
      );
      final beforePlayback = frames.length;
      rest.crossFadeTo(moving, const Duration(milliseconds: 250));
      await until(
        () => moving.weight == 1 && moving.position > Duration.zero,
        'crossfade',
      );
      moving.pause();
      moving.seek(const Duration(milliseconds: 500));
      final beforeSeek = frames.length;
      await until(() => frames.length > beforeSeek, 'seek presentation');
      expect(mesh.geometry.positions.first, 3);
      expect(instance.nodes[1]!.position.x, 2);
      expect(events, isEmpty);
      expect(
        frames.skip(beforePlayback).any((f) => f.uploadedBytes > 0),
        isTrue,
      );
      expect(siblingMesh.geometry.capture(), same(siblingGeometry));

      moving.reverse = true;
      moving.seek(const Duration(milliseconds: 50));
      final reverseSamples = <Duration>[moving.position];
      recorder.onFrame = () => reverseSamples.add(moving.position);
      moving.play();
      timeline.reverse = true;
      timeline.seek(const Duration(seconds: 1));
      timeline.play();
      await until(() => events.length >= 4, 'reverse loop markers');
      recorder.onFrame = null;
      expect(moving.isPlaying, isTrue);
      expect(
        List.generate(
          reverseSamples.length - 1,
          (i) => reverseSamples[i + 1] > reverseSamples[i],
        ).any((wrapped) => wrapped),
        isTrue,
        reason:
            'The action clock must wrap independently while running backward.',
      );
      timeline.pause();
      moving.pause();
      expect(events.take(4).map((e) => e.marker.id), [
        'end',
        'middle',
        'start',
        'end',
      ]);
      expect(moving.position, greaterThanOrEqualTo(Duration.zero));
      expect(moving.position, lessThanOrEqualTo(const Duration(seconds: 1)));
      moving.crossFadeTo(rest, const Duration(milliseconds: 100));
      await until(() => rest.weight == 1, 'return to rest');
      rest.pause();
      moving.pause();
      final additive = timeline.createAction(
        modelClip(instance, model.animations.single),
        additive: true,
        weight: .5,
        referenceTime: const Duration(milliseconds: 250),
      );
      additive.seek(const Duration(seconds: 1));
      expect(mesh.geometry.positions.first, 2);
      final beforeResize = frames.length;
      await tester.pumpWidget(view(220, 180));
      await until(
        () =>
            frames.length > beforeResize &&
            frames.last.physicalSize.width < wideSize.width,
        'narrow surface resize',
      );
      final narrowSize = frames.last.physicalSize;
      expect(tester.getSize(find.byType(SceneView)), const Size(220, 180));
      expect(narrowSize.height, lessThan(wideSize.height));
      expect(mesh.geometry.positions.first, 2);
      expect(frames.map((f) => f.presentationPath), everyElement(path));
      expect(frames.map((f) => f.readbackBytes), everyElement(0));
      expect(frames.map((f) => f.drawCalls), everyElement(2));
      expect(siblingMesh.geometry.capture(), same(siblingGeometry));
      final presented = await diagnostics();
      expect(
        presented['presented'] as int,
        greaterThan(baseline['presented'] as int),
      );
      expect(presented['readbackBytes'], baseline['readbackBytes']);
      additive.dispose();
      moving.dispose();
      rest.dispose();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      expect(() => moving.play(), throwsStateError);
      final closed = await diagnostics();
      expect(closed['renderers'], baseline['renderers']);
      expect(closed['sessions'], baseline['sessions']);
      expect(closed[android ? 'surfaces' : 'heldDrawables'], 0);
      expect(closed['readbackBytes'], baseline['readbackBytes']);
      debugPrint(
        'IMPORTED_PRESENTATION backend=${info.backend} path=${path.name} '
        'frames=${frames.length} wide=${wideSize.width}x${wideSize.height} '
        'narrow=${narrowSize.width}x${narrowSize.height} readbackBytes=0 cleanup=pass',
      );
    },
  );
}
