part of '../../zyren_game_ai.dart';

final class CameraObservation {
  final String episodeId, cameraProfileHash;
  final GameEntityHandle entity;
  final int worldRevision;
  final SensorCaptureReceipt receipt;
  final PhysicsPose? capturedActorPose;
  final double capturedMountYaw;
  final Vec3? capturedCameraPosition;
  final Quat? capturedCameraRotation;
  final MlTensor tensor;
  final Duration preprocessingTime;
  const CameraObservation(
    this.episodeId,
    this.entity,
    this.worldRevision,
    this.receipt,
    this.tensor,
    this.preprocessingTime, {
    this.cameraProfileHash = '',
    this.capturedActorPose,
    this.capturedMountYaw = 0,
    this.capturedCameraPosition,
    this.capturedCameraRotation,
  });
}

/// Samples completed native pixels for the exact requested observer and tick.
/// Call capture before assembly and await it when your host can hold that tick.
/// Pending, late, cancelled and unsupported captures remain unknown/unavailable.
final class CameraSensor implements GameSensor {
  final CameraProfile profile;
  @override
  final String id;
  final SensorCapturePool _pool;
  CameraObservation? _latest;
  String? _pending;
  String? _failure;
  bool _closed = false;
  int _serial = 0;
  CameraSensor(
    this.profile, {
    required Future<RenderBackend> Function() openBackend,
    this.id = 'camera',
    int maxBytes = 16 * 1024 * 1024,
  }) : _pool = SensorCapturePool(
         openBackend: openBackend,
         maxPending: 1,
         maxBytes: maxBytes,
       ) {
    _name(id);
  }
  @override
  int get queryBudget => 0;
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    configurationHash: profile.hash,
    range: profile.far,
    cadenceTicks: cadenceTicks,
    latencyTicks: profile.latencyTicks,
    fields: [
      for (var c = 0; c < 3; c++)
        ObservationField(
          'rgb$c',
          width: profile.width * profile.height,
          min: Float32List.fromList([
            (0 - profile.mean[c]) / profile.std[c],
          ]).first,
          max: Float32List.fromList([
            (1 - profile.mean[c]) / profile.std[c],
          ]).first,
        ),
      if (profile.depth)
        ObservationField(
          'depth',
          width: profile.width * profile.height,
          min: 0,
          max: 1,
        ),
      if (profile.depth)
        ObservationField(
          'depthValid',
          width: profile.width * profile.height,
          min: 0,
          max: 1,
        ),
    ],
  );
  CameraObservation? get latest => _latest;
  bool get isClosed => _closed;
  int get pendingCount => _pool.pendingCount;
  int get reservedBytes => _pool.reservedBytes;
  Future<CameraObservation> capture({
    required SensorSnapshot snapshot,
    required GameEntityHandle entity,
    required Scene scene,
    double mountYaw = 0,
  }) async {
    if (!mountYaw.isFinite || mountYaw.abs() > math.pi) {
      throw ArgumentError("Camera mount yaw must be finite and bounded.");
    }
    if (_closed ||
        _pending != null ||
        !snapshot.isCurrent ||
        snapshot.tick % cadenceTicks != 0 ||
        !snapshot.entities.containsKey(entity)) {
      throw StateError('Camera cannot capture this observer/tick.');
    }
    final actor = snapshot.entities[entity]!;
    final actorPose = actor.pose;
    final rotation =
        actorPose.rotation * Quat.axisAngle(const Vec3(0, 1, 0), mountYaw);
    final origin =
        actor.pose.position + actor.pose.rotation.rotate(profile.offset);
    final camera = PerspectiveCamera(
      position: origin,
      target: origin + rotation.rotate(profile.forward),
      up: rotation.rotate(profile.up),
      fieldOfView: profile.fieldOfView,
      near: profile.near,
      far: profile.far,
    );
    final requestId = '$id-${++_serial}';
    _pending = requestId;
    _failure = null;
    _latest = null;
    try {
      final receipt = await _pool.capture(
        SensorCaptureRequest(
          id: requestId,
          tick: snapshot.tick,
          scene: scene,
          camera: camera,
          size: PhysicalSize(profile.width, profile.height),
          depth: profile.depth,
        ),
      );
      if (_closed || _pending != requestId || !snapshot.isCurrent) {
        throw SensorCaptureCancelled(requestId);
      }
      final clock = Stopwatch()..start();
      final tensor = profile.preprocess(receipt.image, receipt.depth);
      final observation = CameraObservation(
        snapshot.episodeId,
        entity,
        snapshot.worldRevision,
        receipt,
        tensor,
        clock.elapsed,
        cameraProfileHash: profile.hash,
        capturedActorPose: actorPose,
        capturedMountYaw: mountYaw,
        capturedCameraPosition: origin,
        capturedCameraRotation: rotation,
      );
      _latest = observation;
      return observation;
    } catch (error) {
      if (_pending == requestId) {
        _failure = error is UnsupportedError
            ? 'unsupported-camera-output'
            : 'capture-failed';
      }
      rethrow;
    } finally {
      if (_pending == requestId) _pending = null;
    }
  }

  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final value = _latest;
    if (_closed ||
        value == null ||
        value.episodeId != snapshot.episodeId ||
        value.entity != entity ||
        value.worldRevision != snapshot.worldRevision ||
        value.receipt.tick != snapshot.tick ||
        !snapshot.isCurrent) {
      return _empty(
        this,
        snapshot.tick,
        _failure == 'unsupported-camera-output'
            ? SensorState.unavailable
            : SensorState.unknown,
        _failure ?? 'camera-pending-or-stale',
      );
    }
    final values = value.tensor.float32Values;
    final validity = List<int>.filled(values.length, 1);
    if (profile.depth) {
      final count = profile.width * profile.height;
      for (var i = 0; i < count; i++) {
        validity[count * 3 + i] = value.receipt.depth!.validity[i];
      }
    }
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: SensorState.known,
      provenance: SensorProvenance.visible,
      configurationHash: profile.hash,
      values: values,
      validity: validity,
    );
  }

  void invalidate() {
    if (_pending case final String requestId) _pool.cancel(requestId);
    _latest = null;
    _pending = null;
    _failure = null;
    _serial++;
  }

  Future<void> recreate() async {
    invalidate();
    await _pool.recreate();
  }

  Future<void> close() async {
    _closed = true;
    invalidate();
    await _pool.close();
  }
}
