import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';

void main() {
  final actor = GameEntityTable().spawn('camera-actor');
  test(
    'flat encoder admits only matching known camera and captured own-body',
    () {
      for (final mode in ['rgb', 'depth', 'combined']) {
        final profile = TrainingVisualProfiles.forFamily(
          family: 'guard',
          mode: mode,
        );
        final pixels = List<double>.filled(profile.camera.widthElements, .5);
        if (profile.camera.depth) {
          for (var i = 84 * 84 * 4; i < pixels.length; i++) {
            pixels[i] = 1;
          }
          pixels[84 * 84 * 3] = 0;
          pixels[84 * 84 * 4] = 0;
        }
        final frame = profile.frame(
          episodeId: 'ep',
          entity: actor,
          tick: 4,
          worldRevision: 7,
          captured: MlTensor.float32([
            1,
            profile.camera.channels,
            84,
            84,
          ], pixels),
          ownBody: [1, 2, 3, 4, 5, 1, 0, 1],
        );
        final encoded = VisualPolicyEncoder(profile).encode(frame);
        expect(encoded.shape, [1, profile.width]);
        expect(encoded.float32Values.sublist(profile.imageWidth), [
          1,
          2,
          3,
          4,
          5,
          1,
          0,
          1,
        ]);
        expect(frame.entityMask, [0]);
        expect(frame.visibleIds, isEmpty);
        expect(frame.readings.map((r) => r.sensorId), ['camera', 'own-body']);
        expect(
          () => VisualPolicyEncoder(
            TrainingVisualProfiles.forFamily(family: 'vehicle', mode: mode),
          ).encode(frame),
          throwsStateError,
        );
      }
    },
  );
  test(
    'pending, failed camera and missing body remain unknown and cannot encode',
    () {
      final profile = TrainingVisualProfiles.forFamily(
        family: 'vehicle',
        mode: 'rgb',
      );
      for (final state in [SensorState.unknown, SensorState.unavailable]) {
        final frame = profile.frame(
          episodeId: 'ep',
          entity: actor,
          tick: 5,
          worldRevision: 5,
          cameraState: state,
          reason: 'camera-deadline',
          ownBody: [1, 2, 3, 4, 5, 1, 0, 1],
        );
        expect(frame.readings.first.state, state);
        expect(frame.readings.first.reason, 'camera-deadline');
        expect(frame.readings.last.state, SensorState.known);
        expect(
          () => VisualPolicyEncoder(profile).encode(frame),
          throwsStateError,
        );
      }
      final captured = MlTensor.float32([
        1,
        3,
        84,
        84,
      ], List.filled(84 * 84 * 3, 0));
      final missing = profile.frame(
        episodeId: 'ep',
        entity: actor,
        tick: 5,
        worldRevision: 5,
        captured: captured,
      );
      expect(missing.readings.first.state, SensorState.known);
      expect(missing.readings.last.state, SensorState.unknown);
      expect(
        () => VisualPolicyEncoder(profile).encode(missing),
        throwsStateError,
      );
      expect(
        () => profile.frame(
          episodeId: 'ep',
          entity: actor,
          tick: 5,
          worldRevision: 5,
          cameraState: SensorState.known,
        ),
        throwsArgumentError,
      );
    },
  );
}
