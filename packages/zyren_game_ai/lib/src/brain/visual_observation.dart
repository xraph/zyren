part of '../../zyren_game_ai.dart';

/// Builds a permitted flat frame from completed pixels and captured own-body.
/// An absent or failed input stays explicit and cannot enter visual inference.
extension TrainingVisualObservation on TrainingVisualProfile {
  ObservationFrame frame({
    required String episodeId,
    required GameEntityHandle entity,
    required int tick,
    required int worldRevision,
    MlTensor? captured,
    List<double>? ownBody,
    SensorState? cameraState,
    String? reason,
  }) {
    _name(episodeId);
    if (tick < 0 || worldRevision < 0) {
      throw ArgumentError('Visual frame tick or revision is invalid.');
    }
    final state =
        cameraState ??
        (captured == null ? SensorState.unknown : SensorState.known);
    if ((captured == null) == (state == SensorState.known)) {
      throw ArgumentError('Visual camera state and completed pixels disagree.');
    }
    final bodyKnown = ownBody != null && _visualBodyValid(ownBody);
    final body = bodyKnown
        ? List<double>.from(ownBody)
        : List<double>.filled(bodyWidth, 0);
    final image = captured == null
        ? List<double>.filled(imageWidth, 0)
        : compose(
            captured,
            ownBody: [0, 0, 0, 0, 0, 1, 0, 1],
          ).float32Values.sublist(0, imageWidth);
    final readings = [
      SensorReading(
        sensorId: 'camera',
        tick: tick,
        state: state,
        provenance: SensorProvenance.visible,
        configurationHash: configurationHash,
        values: image,
        validity: captured == null
            ? List.filled(imageWidth, 0)
            : _visualImageValidity(this, image),
        reason: captured == null ? reason ?? 'camera-pending-or-stale' : null,
      ),
      SensorReading(
        sensorId: 'own-body',
        tick: tick,
        state: bodyKnown ? SensorState.known : SensorState.unknown,
        provenance: SensorProvenance.body,
        configurationHash: configurationHash,
        values: body,
        validity: List.filled(bodyWidth, bodyKnown ? 1 : 0),
        reason: bodyKnown ? null : 'body-unavailable',
      ),
    ];
    return ObservationFrame._(
      episodeId: episodeId,
      schemaHash: spec.hash,
      sensorProfileHash: configurationHash,
      entity: entity,
      tick: tick,
      worldRevision: worldRevision,
      readings: readings,
      entities: [null],
      entityMask: [0],
      tensor: MlTensor.float32([1, width], [...image, ...body]),
    );
  }
}

/// The model embeds affine normalization. This encoder admits raw camera/body
/// values once, while refusing unknown pixels or substituted zero observations.
final class VisualPolicyEncoder implements PolicyObservationEncoder {
  final TrainingVisualProfile profile;
  const VisualPolicyEncoder(this.profile);
  @override
  String get id => 'visual-camera-body-v1:${profile.configurationHash}';
  @override
  MlTensor encode(ObservationFrame frame) {
    if (frame.schemaHash != profile.spec.hash ||
        frame.sensorProfileHash != profile.configurationHash ||
        frame.readings.length != 2 ||
        frame.tensor.dtype != MlDtype.float32 ||
        frame.tensor.shape.length != 2 ||
        frame.tensor.shape[0] != 1 ||
        frame.tensor.shape[1] != profile.width) {
      throw StateError('Visual frame schema or mode differs.');
    }
    final image = frame.readings[0], body = frame.readings[1];
    if (image.sensorId != 'camera' ||
        body.sensorId != 'own-body' ||
        [image, body].any(
          (r) =>
              r.state != SensorState.known ||
              r.tick != frame.tick ||
              r.configurationHash != profile.configurationHash,
        ) ||
        image.values.length != profile.imageWidth ||
        body.values.length != profile.bodyWidth ||
        body.validity.any((v) => v != 1) ||
        !_visualBodyValid(body.values)) {
      throw StateError('Visual camera or own-body observation is unavailable.');
    }
    final expectedValidity = _visualImageValidity(profile, image.values);
    if (List.generate(
      expectedValidity.length,
      (i) => i,
    ).any((i) => image.validity[i] != expectedValidity[i])) {
      throw StateError('Visual depth masks are inconsistent.');
    }
    return frame.tensor;
  }
}

bool _visualBodyValid(List<double> body) {
  if (body.length != 8 ||
      body.any((v) => !v.isFinite || v.abs() > 10000) ||
      body[5] != 1 ||
      body[6] != 0 ||
      (body[7] != 0 && body[7] != 1)) {
    throw ArgumentError('Captured own-body ABI differs.');
  }
  return body[7] == 1;
}

List<int> _visualImageValidity(
  TrainingVisualProfile profile,
  List<double> values,
) {
  if (values.length != profile.imageWidth ||
      values.any((v) => !v.isFinite || v < 0 || v > 1)) {
    throw StateError('Completed normalized camera planes are unavailable.');
  }
  final mask = List<int>.filled(values.length, 1);
  if (profile.mode != 'rgb') {
    final count = profile.camera.width * profile.camera.height;
    final depthOffset = profile.mode == 'depth' ? 0 : count * 3;
    final maskOffset = depthOffset + count;
    for (var i = 0; i < count; i++) {
      final valid = values[maskOffset + i];
      if (valid != 0 && valid != 1 ||
          valid == 0 && values[depthOffset + i] != 0) {
        throw StateError('Native depth and mask planes disagree.');
      }
      mask[depthOffset + i] = valid.toInt();
    }
  }
  return mask;
}
