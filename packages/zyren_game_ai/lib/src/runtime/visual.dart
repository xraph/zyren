part of '../../runtime.dart';

/// Bounded sensor payload admission, not a measurement of physical GPU memory.
/// Native capture slots remain reserved until render and inference complete.
final class GameVisualRuntimeLimits {
  final int maxActors, maxInFlight, maxOutputBytes;
  final Duration deadline;
  const GameVisualRuntimeLimits({
    this.maxActors = 4,
    this.maxInFlight = 2,
    this.maxOutputBytes = 2 * 1024 * 1024,
    this.deadline = const Duration(milliseconds: 16),
  });
  void validate() {
    if (maxActors < 1 ||
        maxActors > 16 ||
        maxInFlight < 1 ||
        maxInFlight > maxActors ||
        maxOutputBytes < 84 * 84 * 9 ||
        maxOutputBytes > 16 * 1024 * 1024 ||
        deadline.inMicroseconds < 1 ||
        deadline.inMicroseconds > 20000) {
      throw ArgumentError('Invalid visual actor, payload or deadline limits.');
    }
  }
}

final class _RuntimeCamera {
  final TrainingVisualProfile profile;
  CameraSensor? sensor;
  final CameraSensor? Function() openSensor;
  final void Function() releaseSensor;
  Future<void>? pending;
  Timer? timer;
  CameraObservation? latest;
  String? failure;
  int serial = 0;
  _RuntimeCamera(this.profile, this.openSensor, this.releaseSensor);
  void invalidate() {
    serial++;
    timer?.cancel();
    timer = null;
    sensor?.invalidate();
    latest = null;
  }

  Future<void> close() async {
    invalidate();
    await pending;
    if (sensor case final owned?) {
      try {
        await owned.close();
      } finally {
        sensor = null;
        releaseSensor();
      }
    }
  }
}

extension _GameVisualRuntime on GameLevelAi {
  CameraSensor? _openCameraSensor(
    GameEntityHandle actor,
    TrainingVisualProfile profile,
  ) {
    if (openCameraBackend == null || _cameraOwners >= visualLimits.maxActors) {
      return null;
    }
    _cameraOwners++;
    return CameraSensor(
      profile.camera,
      maxBytes: visualLimits.maxOutputBytes,
      openBackend: () => openCameraBackend!(actor, profile),
    );
  }

  void _senseVisual(_RuntimeBrain actor, SensorSnapshot snapshot) {
    final camera = actor.camera!, profile = camera.profile;
    final capturedBody = snapshot.entities[actor.identity.entity];
    List<double>? body;
    try {
      if (capturedBody != null) {
        body = profile.ownBody(
          pose: capturedBody.pose,
          velocity: capturedBody.velocity,
          angularVelocity: capturedBody.angularVelocity,
        );
      }
    } on ArgumentError {
      /* Body data remains explicitly unknown. */
    }
    final sensor = camera.sensor ??= camera.openSensor();
    final outputBytes =
        profile.camera.width *
        profile.camera.height *
        (profile.camera.depth ? 9 : 4);
    final reason = sensor == null
        ? openCameraBackend == null
              ? 'camera-backend-unavailable'
              : 'camera-owner-draining'
        : body == null
        ? 'body-unavailable'
        : actor.control?.isActive != true && actor.policy != null
        ? 'camera-control-unavailable'
        : camera.pending != null
        ? 'camera-previous-capture-draining'
        : _cameraJobs.length >= visualLimits.maxInFlight ||
              outputBytes > visualLimits.maxOutputBytes - _cameraBytes
        ? 'camera-admission-full'
        : 'camera-pending';
    camera.latest = null;
    camera.failure = reason;
    actor.frame = profile.frame(
      episodeId: snapshot.episodeId,
      entity: actor.identity.entity,
      tick: snapshot.tick,
      worldRevision: snapshot.worldRevision,
      ownBody: body,
      cameraState: openCameraBackend == null
          ? SensorState.unavailable
          : SensorState.unknown,
      reason: reason,
    );
    if (actor.policy != null) actor.brain.observe(actor.frame!);
    if (reason != 'camera-pending') return;
    final who = actor.identity.entity, session = _session!;
    final epoch = session.epoch, control = actor.control?.generation;
    final serial = ++camera.serial;
    final deadline = DateTime.now().add(visualLimits.deadline);
    final clock = Stopwatch()..start();
    bool current() =>
        !_closed &&
        identical(_actors[who], actor) &&
        session.entities.isAlive(who) &&
        runtime().isEntityActive(who) &&
        !runtime().isPaused &&
        session.tick == snapshot.tick &&
        session.epoch == epoch &&
        actor.control?.generation == control &&
        camera.serial == serial;
    camera.timer = Timer(visualLimits.deadline, () {
      if (!current()) return;
      sensor!.invalidate();
      camera.latest = null;
      camera.failure = 'camera-deadline';
      actor.frame = profile.frame(
        episodeId: snapshot.episodeId,
        entity: who,
        tick: snapshot.tick,
        worldRevision: snapshot.worldRevision,
        ownBody: body,
        reason: 'camera-deadline',
      );
      actor.policy?.invalidatePending(preserveState: true);
      onChanged?.call();
    });
    final job = _runVisual(actor, snapshot, body!, deadline, clock, current);
    camera.pending = job;
    _cameraBytes += outputBytes;
    _cameraJobs.add(job);
    unawaited(
      job.then<void>(
        (_) {
          camera.timer?.cancel();
          camera.timer = null;
          camera.pending = null;
          _cameraJobs.remove(job);
          _cameraBytes -= outputBytes;
        },
        onError: (Object error, StackTrace trace) {
          // _runVisual reports sensor failures. Unexpected errors remain owned.
          camera.timer?.cancel();
          camera.timer = null;
          camera.pending = null;
          _cameraJobs.remove(job);
          _cameraBytes -= outputBytes;
          _retirementError ??= error;
          _retirementTrace ??= trace;
        },
      ),
    );
  }

  Future<void> _runVisual(
    _RuntimeBrain actor,
    SensorSnapshot snapshot,
    List<double> body,
    DateTime deadline,
    Stopwatch clock,
    bool Function() current,
  ) async {
    final camera = actor.camera!, profile = camera.profile;
    try {
      final pixels = await camera.sensor!.capture(
        snapshot: snapshot,
        entity: actor.identity.entity,
        scene: runtime().scene,
      );
      if (!current() ||
          clock.elapsed >= visualLimits.deadline ||
          pixels.receipt.tick != snapshot.tick ||
          pixels.episodeId != snapshot.episodeId ||
          pixels.entity != actor.identity.entity ||
          pixels.worldRevision != snapshot.worldRevision) {
        return;
      }
      final frame = actor.frame = profile.frame(
        episodeId: snapshot.episodeId,
        entity: actor.identity.entity,
        tick: snapshot.tick,
        worldRevision: snapshot.worldRevision,
        captured: pixels.tensor,
        ownBody: body,
      );
      camera.latest = pixels;
      camera.failure = null;
      final policy = actor.policy;
      if (policy != null && actor.control?.isActive == true) {
        actor.brain.observe(frame);
        policy.observe(frame);
        final context = _context(actor, scripted: false);
        _group!.record(context);
        await policy.request(
          context,
          legality: context.legality,
          deadline: deadline,
        );
      }
      if (current()) onChanged?.call();
    } catch (error) {
      if (!current()) return;
      final unavailable = error is UnsupportedError;
      camera.failure = camera.failure == 'camera-deadline'
          ? camera.failure
          : unavailable
          ? 'unsupported-camera-output'
          : 'camera-capture-failed';
      camera.latest = null;
      actor.frame = profile.frame(
        episodeId: snapshot.episodeId,
        entity: actor.identity.entity,
        tick: snapshot.tick,
        worldRevision: snapshot.worldRevision,
        ownBody: body,
        cameraState: unavailable
            ? SensorState.unavailable
            : SensorState.unknown,
        reason: camera.failure,
      );
      onChanged?.call();
    }
  }
}
