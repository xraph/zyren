import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/visual_runtime_fixture.dart';

final class _HeldNativeBackend implements RenderBackend {
  final RenderBackend backend;
  final started = Completer<void>(), release = Completer<void>();
  int completed = 0, closes = 0;
  _HeldNativeBackend(this.backend);
  @override
  DeviceCapabilities get capabilities => backend.capabilities;
  @override
  Future<FrameOutput> render(FrameSubmission frame) async {
    final output = backend.render(frame);
    started.complete();
    final actual = await output;
    completed++;
    await release.future;
    return actual;
  }

  @override
  Future<void> close() async {
    closes++;
    await backend.close();
  }
}

void main() {
  final gpu = Platform.environment['RUN_NATIVE_GPU'] == '1';
  test(
    'missing camera is unavailable and visual actor limits fail before play',
    () async {
      final f = VisualRuntimeFixture();
      try {
        await f.start();
        await f.ai.flush();
        final frame = f.ai.observation(f.ai.actors.single)!;
        expect(frame.readings.first.state, SensorState.unavailable);
        expect(frame.readings.first.reason, 'camera-backend-unavailable');
        expect(
          () => VisualPolicyEncoder(f.profile).encode(frame),
          throwsStateError,
        );
        expect(f.ai.pendingCameraCaptures, 0);
      } finally {
        await f.close();
      }
      final full = VisualRuntimeFixture(actorCount: 5);
      try {
        await expectLater(full.start(), throwsStateError);
      } finally {
        await full.close();
      }
      expect(
        () => const GameVisualRuntimeLimits(maxActors: 17).validate(),
        throwsArgumentError,
      );
      expect(
        () => const GameVisualRuntimeLimits(
          deadline: Duration(milliseconds: 21),
        ).validate(),
        throwsArgumentError,
      );
    },
  );
  test(
    'actual native pixels produce exact flat ABI and due-tick recurrent action',
    () async {
      final f = VisualRuntimeFixture(
        backend: NativeBackend.create,
        learned: true,
      );
      try {
        await f.start();
        await f.ai.flush();
        for (var i = 0; i < 30 && f.ai.completedDecisions == 0; i++) {
          await f.step();
        }
        expect(f.ai.completedDecisions, greaterThan(0));
        final actor = f.ai.actors.single,
            frame = f.ai.observation(f.ai.actors.single)!;
        expect(frame.schemaHash, f.profile.spec.hash);
        expect(frame.tensor.shape, [1, f.profile.width]);
        expect(
          frame.readings.every((r) => r.state == SensorState.known),
          isTrue,
        );
        final image = f.ai.cameraObservation(actor)!;
        expect(image.receipt.tick, frame.tick);
        expect(image.worldRevision, frame.worldRevision);
        expect(image.receipt.depth!.validity.any((v) => v == 1), isTrue);
        expect(
          VisualPolicyEncoder(
            f.profile,
          ).encode(frame).float32Values.sublist(f.profile.imageWidth + 5),
          [1, 0, 1],
        );
        expect(f.ai.group!.stateFor(actor)!.version, greaterThan(0));
        expect(
          f.ai.group!
              .brainFor(actor)!
              .decisions
              .receipts
              .where((r) => r.accepted)
              .every((r) => r.applicationTick == r.applyTick),
          isTrue,
        );
        f.runtime.pause();
        await f.ai.flush();
        expect(f.ai.cameraObservation(actor), isNull);
        expect(f.ai.observation(actor), isNull);
        await f.close();
        expect(f.ai.ownedCameraSensors, 0);
        expect(f.ai.reservedCameraOutputBytes, 0);
      } finally {
        await f.close();
      }
    },
    skip: !gpu,
  );
  test(
    'deadline never admits late native pixels or releases a running capture slot',
    () async {
      final backend = _HeldNativeBackend(await NativeBackend.create());
      final f = VisualRuntimeFixture(
        backend: () async => backend,
        learned: true,
      );
      try {
        await f.start();
        await backend.started.future;
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final frame = f.ai.observation(f.ai.actors.single)!;
        expect(frame.readings.first.reason, 'camera-deadline');
        expect(frame.readings.first.state, SensorState.unknown);
        expect(f.ai.pendingCameraCaptures, 1);
        expect(f.ai.reservedCameraOutputBytes, 84 * 84 * 9);
        expect(f.ai.group!.brainFor(f.ai.actors.single)!.hasPending, isFalse);
        backend.release.complete();
        await f.ai.flush();
        expect(f.ai.cameraObservation(f.ai.actors.single), isNull);
        expect(f.ai.completedDecisions, 0);
        expect(f.ai.pendingCameraCaptures, 0);
        expect(f.ai.reservedCameraOutputBytes, 0);
        expect(backend.completed, 1);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await f.close();
      }
    },
    skip: !gpu,
  );
  test(
    'stale cancelled capture keeps global slots until real native render drain',
    () async {
      final backend = _HeldNativeBackend(await NativeBackend.create());
      final f = VisualRuntimeFixture(
        backend: () async => backend,
        actorCount: 2,
        limits: const GameVisualRuntimeLimits(
          maxActors: 2,
          maxInFlight: 1,
          maxOutputBytes: 84 * 84 * 9,
        ),
      );
      try {
        await f.start();
        await backend.started.future;
        expect(f.ai.pendingCameraCaptures, 1);
        expect(f.ai.reservedCameraOutputBytes, 84 * 84 * 9);
        f.runtime.simulation!.step();
        expect(f.ai.pendingCameraCaptures, 1);
        expect(
          f.ai.observation(f.ai.actors.last)!.readings.first.reason,
          'camera-admission-full',
        );
        f.runtime.pause();
        var closed = false;
        final closing = f.close().then((_) => closed = true);
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(closed, isFalse);
        expect(f.ai.pendingCameraCaptures, 1);
        backend.release.complete();
        await closing;
        expect(backend.completed, 1);
        expect(
          backend.closes,
          1,
        ); // The second sensor owner never opened its unadmitted backend.
        expect(f.ai.pendingCameraCaptures, 0);
        expect(f.ai.reservedCameraOutputBytes, 0);
        expect(f.ai.ownedCameraSensors, 0);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await f.close();
      }
    },
    skip: !gpu,
  );
}
