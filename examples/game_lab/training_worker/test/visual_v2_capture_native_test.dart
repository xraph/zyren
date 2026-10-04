import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/sensors.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_lab_training_worker/visual_v2_oracle.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

final class _HeldBackend implements RenderBackend {
  final RenderBackend native;
  final started = Completer<void>(), release = Completer<void>();
  int completed = 0, closes = 0;
  _HeldBackend(this.native);
  @override
  DeviceCapabilities get capabilities => native.capabilities;
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final pending = native.render(submission);
    if (!started.isCompleted) started.complete();
    final output = await pending;
    completed++;
    await release.future;
    return output;
  }

  @override
  Future<void> close() async {
    closes++;
    await native.close();
  }
}

void main() {
  final enabled = Platform.environment['RUN_NATIVE_GPU'] == '1';
  final profile = VisualNavigationProfile(family: 'guard', mode: 'combined');
  SensorSnapshot snapshot(GameEntityHandle actor, PhysicsPose pose) =>
      SensorSnapshot(
        episodeId: 'capture-v2',
        tick: 5,
        worldRevision: 1,
        entities: [SensorEntity(handle: actor, pose: pose)],
        colliders: {},
        currentRevision: () => 1,
        geometryLoaded: (_, _) => true,
      );
  Scene scene() => Scene()
    ..add(
      Mesh(
        SphereGeometry(radius: .25),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      )..position = const Vec3(0, 1, 4),
    );

  test(
    'actual mounted capture keeps submitted pose and class ablation removes goal',
    () async {
      final actor = GameEntityTable().spawn('observer');
      var ownPose = PhysicsPose(position: const Vec3(0, .7, 0));
      final submitted = ownPose;
      final backend = _HeldBackend(await NativeBackend.create());
      final sensor = CameraSensor(
        profile.camera,
        openBackend: () async => backend,
      );
      final visible = scene();
      try {
        final pending = sensor.capture(
          snapshot: snapshot(actor, ownPose),
          entity: actor,
          scene: visible,
          mountYaw: .15,
        );
        await backend.started.future;
        ownPose = PhysicsPose(position: const Vec3(50, .7, 50));
        backend.release.complete();
        final captured = await pending;
        expect(captured.capturedActorPose!.position, submitted.position);
        expect(captured.capturedActorPose!.position, isNot(ownPose.position));
        expect(captured.capturedMountYaw, .15);
        expect(captured.cameraProfileHash, profile.camera.hash);
        expect(
          visualV2RasterOracle(captured, profile).target.visibleProbability,
          greaterThan(.9),
        );
        visible.children.single.visible = false;
        final absent = await sensor.capture(
          snapshot: snapshot(actor, submitted),
          entity: actor,
          scene: visible,
          mountYaw: .15,
        );
        expect(visualV2RasterOracle(absent, profile).target.visibleProbability, 0);
        expect(
          absent.tensor.float32Values,
          isNot(captured.tensor.float32Values),
        );
        final legacy = CameraObservation(
          captured.episodeId,
          actor,
          1,
          captured.receipt,
          captured.tensor,
          Duration.zero,
        );
        expect(legacy.capturedActorPose, isNull);
        await expectLater(
          sensor.capture(
            snapshot: snapshot(actor, submitted),
            entity: actor,
            scene: visible,
            mountYaw: double.nan,
          ),
          throwsArgumentError,
        );
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await sensor.close();
      }
      expect(sensor.pendingCount, 0);
      expect(sensor.reservedBytes, 0);
      expect(backend.closes, 1);
    },
    skip: !enabled,
  );

  test(
    'mounted in-flight capture cancels and drains before backend owner release',
    () async {
      final actor = GameEntityTable().spawn('observer');
      final backend = _HeldBackend(await NativeBackend.create());
      final sensor = CameraSensor(
        profile.camera,
        openBackend: () async => backend,
      );
      final pending = sensor.capture(
        snapshot: snapshot(actor, PhysicsPose(position: const Vec3(0, .7, 0))),
        entity: actor,
        scene: scene(),
        mountYaw: .25,
      );
      pending.ignore();
      await backend.started.future;
      final closing = sensor.close();
      expect(backend.closes, 0);
      backend.release.complete();
      await expectLater(pending, throwsA(isA<SensorCaptureCancelled>()));
      await closing;
      await sensor.close();
      expect(backend.completed, 1);
      expect(backend.closes, 1);
      expect(sensor.isClosed, true);
      expect(sensor.pendingCount, 0);
      expect(sensor.reservedBytes, 0);
    },
    skip: !enabled,
  );
}
