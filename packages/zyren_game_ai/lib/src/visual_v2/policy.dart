part of '../../visual_v2.dart';

/// Admits captured image/body records. Normalization stays inside the model.
final class VisualNavigationPolicyEncoder implements PolicyObservationEncoder {
  final VisualNavigationProfile profile;
  const VisualNavigationPolicyEncoder(this.profile);
  @override
  String get id => 'visual-navigation-v2:${profile.hash}';
  @override
  MlTensor encode(ObservationFrame frame) {
    if (frame.schemaHash != profile.spec.hash ||
        frame.sensorProfileHash != profile.hash ||
        frame.readings.length != 2 ||
        frame.tensor.dtype != MlDtype.float32 ||
        !_shapeEquals(frame.tensor.shape, [1, profile.width])) {
      throw StateError('Captured visual navigation frame differs.');
    }
    final image = frame.readings[0], body = frame.readings[1];
    if (image.sensorId != 'camera' ||
        body.sensorId != 'own-body' ||
        image.provenance != SensorProvenance.visible ||
        body.provenance != SensorProvenance.body ||
        [image, body].any(
          (r) =>
              r.state != SensorState.known ||
              r.tick != frame.tick ||
              r.configurationHash != profile.hash,
        ) ||
        image.values.length != profile.imageWidth ||
        body.values.length != 10 ||
        body.validity.any((v) => v != 1) ||
        body.values[9] != 1 ||
        body.values.any((v) => !v.isFinite || v.abs() > 10000) ||
        (body.values[5] * body.values[5] + body.values[6] * body.values[6] - 1)
                .abs() >
            1e-5 ||
        (body.values[7] * body.values[7] + body.values[8] * body.values[8] - 1)
                .abs() >
            1e-5 ||
        image.values.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw StateError('Captured camera or own-body data is unavailable.');
    }
    final masks = List<int>.filled(profile.imageWidth, 1);
    if (profile.mode != 'rgb') {
      const pixels = 84 * 84;
      final depth = profile.mode == 'depth' ? 0 : pixels * 3;
      for (var i = 0; i < pixels; i++) {
        final valid = image.values[depth + pixels + i];
        if ((valid != 0 && valid != 1) ||
            valid == 0 && image.values[depth + i] != 0) {
          throw StateError('Captured depth mask differs.');
        }
        masks[depth + i] = valid.toInt();
      }
    }
    final tensorValues = frame.tensor.float32Values;
    if (List.generate(
          masks.length,
          (i) => i,
        ).any((i) => image.validity[i] != masks[i]) ||
        List.generate(profile.width, (i) => i).any(
          (i) =>
              tensorValues[i] !=
              (i < profile.imageWidth
                  ? image.values[i]
                  : body.values[i - profile.imageWidth]),
        )) {
      throw StateError('Captured readings and inference tensor differ.');
    }
    return frame.tensor;
  }
}

/// Binds the proposed recurrent estimate ABI without qualifying an artifact.
PolicyContract visualNavigationPolicyContract({
  required VisualNavigationProfile profile,
  required MlModelManifest model,
}) {
  if (model.inputs.length != 4 ||
      model.outputs.length != 3 ||
      model.recurrent.length != 2 ||
      model.recurrent['hidden_h'] != 'next_hidden_h' ||
      model.recurrent['hidden_c'] != 'next_hidden_c') {
    throw ArgumentError('Visual navigation recurrent binding differs.');
  }
  for (final name in ['hidden_h', 'hidden_c']) {
    final input = model.inputs.where((s) => s.name == name).firstOrNull;
    if (input == null ||
        input.dtype != MlDtype.float32 ||
        !_shapeEquals(input.shape, [1, -1, 128]) ||
        !_shapeEquals(input.maxShape, [1, 64, 128])) {
      throw ArgumentError('Visual navigation hidden ABI differs.');
    }
  }
  final observation = model.inputs
      .where((s) => s.name == 'observation')
      .firstOrNull;
  final start = model.inputs
      .where((s) => s.name == 'episode_start')
      .firstOrNull;
  final estimate = model.outputs
      .where((s) => s.name == 'visual_estimate')
      .firstOrNull;
  if (observation == null ||
      !_shapeEquals(observation.shape, [-1, profile.width]) ||
      !_shapeEquals(observation.maxShape, [64, profile.width]) ||
      start == null ||
      !_shapeEquals(start.maxShape, [64]) ||
      estimate == null ||
      !_shapeEquals(estimate.shape, [-1, 74]) ||
      !_shapeEquals(estimate.maxShape, [64, 74])) {
    throw ArgumentError(
      'Visual navigation observation or estimate ABI differs.',
    );
  }
  return PolicyContract(
    model: model,
    observation: profile.spec,
    decoder: ActionDecoder.validatedRecord(
      spec: VisualEstimate.spec,
      validate: (action) {
        VisualEstimate.decode(action.continuous, profile: profile);
        return true;
      },
    ),
    encoder: VisualNavigationPolicyEncoder(profile),
    episodeStartInput: 'episode_start',
    continuousOutput: 'visual_estimate',
    cadenceTicks: 5,
    latencyTicks: 2,
  );
}

bool _shapeEquals(List<int> a, List<int> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);

/// A pending capture stays unknown and cannot be encoded as a known zero image.
extension VisualNavigationObservation on VisualNavigationProfile {
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
    final state =
        cameraState ??
        (captured == null ? SensorState.unknown : SensorState.known);
    if ((captured == null) == (state == SensorState.known)) {
      throw ArgumentError('Completed capture and camera availability differ.');
    }
    final image = captured == null
        ? List<double>.filled(imageWidth, 0)
        : compose(
            captured,
            ownBody: [0, 0, 0, 0, 0, 0, 1, 0, 1, 1],
          ).float32Values.sublist(0, imageWidth);
    final body = ownBody == null
        ? List<double>.filled(10, 0)
        : List<double>.from(ownBody);
    if (body.length != 10 ||
        body.any((v) => !v.isFinite || v.abs() > 10000) ||
        (body[9] != 0 && body[9] != 1)) {
      throw ArgumentError('Captured body layout differs.');
    }
    if (body[9] == 1 &&
        ((body[5] * body[5] + body[6] * body[6] - 1).abs() > 1e-5 ||
            (body[7] * body[7] + body[8] * body[8] - 1).abs() > 1e-5)) {
      throw ArgumentError('Captured heading or mount basis differs.');
    }
    final validity = List<int>.filled(imageWidth, captured == null ? 0 : 1);
    if (captured != null && mode != 'rgb') {
      const pixels = 84 * 84;
      final depth = mode == 'depth' ? 0 : pixels * 3;
      for (var i = 0; i < pixels; i++) {
        validity[depth + i] = image[depth + pixels + i].toInt();
      }
    }
    return ObservationFrame.capturedReadings(
      spec: spec,
      configurationHash: hash,
      episodeId: episodeId,
      entity: entity,
      tick: tick,
      worldRevision: worldRevision,
      readings: [
        SensorReading(
          sensorId: 'camera',
          tick: tick,
          state: state,
          provenance: SensorProvenance.visible,
          values: image,
          validity: validity,
          configurationHash: hash,
          reason: captured == null
              ? reason ?? 'capture-pending-or-stale'
              : null,
        ),
        SensorReading(
          sensorId: 'own-body',
          tick: tick,
          state: body[9] == 1 ? SensorState.known : SensorState.unknown,
          provenance: SensorProvenance.body,
          values: body,
          validity: List.filled(10, body[9] == 1 ? 1 : 0),
          configurationHash: hash,
          reason: body[9] == 1 ? null : 'body-unavailable',
        ),
      ],
    );
  }
}
