import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'six visual profiles pin controller, camera pose and flat own-body ABI',
    () {
      final hashes = <String>{};
      for (final family in ['guard', 'vehicle']) {
        for (final mode in ['rgb', 'depth', 'combined']) {
          final profile = TrainingVisualProfiles.forFamily(
            family: family,
            mode: mode,
          );
          final channels = {'rgb': 3, 'depth': 2, 'combined': 5}[mode]!;
          expect(profile.spec.width, channels * 84 * 84 + 8);
          expect(profile.spec.fields.map((f) => f.name), [
            'camera',
            'own-body',
          ]);
          expect(profile.spec.maxRays, 0);
          expect(profile.fixedHz, 50);
          expect(profile.maxHoldTicks, 2);
          expect(profile.spec.maxEntities, 1);
          expect(profile.spec.latencyTicks, 1);
          expect(profile.spec.cadenceTicks, 1);
          expect(profile.camera.forward, const Vec3(0, 0, 1));
          expect(profile.camera.up, const Vec3(0, 1, 0));
          expect(
            profile.camera.offset,
            Vec3(0, family == 'guard' ? .3 : .6, .35),
          );
          expect(profile.camera.far, 40);
          expect(profile.camera.maxMetres, 40);
          expect(profile.artifactFamily, '$family-visual-$mode');
          expect(profile.spec.configurationHash, profile.configurationHash);
          expect(profile.toJson()['layout'], 'CHW-image-then-own-body');
          expect(
            profile.decoder.spec.hash,
            family == 'guard'
                ? TrainingActions.character.hash
                : TrainingActions.vehicle.hash,
          );
          expect(hashes.add(profile.spec.hash), isTrue);
        }
      }
      expect(
        () => TrainingVisualProfiles.forFamily(family: 'guard', mode: 'labels'),
        throwsArgumentError,
      );
      expect(
        () => TrainingVisualProfiles.forFamily(family: 'observer', mode: 'rgb'),
        throwsArgumentError,
      );
    },
  );

  test(
    'depth mode selects real DV planes and rejects contradictory depth masks',
    () {
      final profile = TrainingVisualProfiles.forFamily(
        family: 'guard',
        mode: 'depth',
      );
      const count = 84 * 84;
      final values = <double>[
        ...List.filled(count, .1),
        ...List.filled(count, .2),
        ...List.filled(count, .3),
        ...List.filled(count, .4),
        ...List.filled(count, 1.0),
      ];
      final body = [2.0, 3.0, 4.0, 5.0, 6.0, 1.0, 0.0, 1.0];
      final output = profile.compose(
        MlTensor.float32([1, 5, 84, 84], values),
        ownBody: body,
      );
      expect(output.shape, [1, count * 2 + 8]);
      expect(output.float32Values.first, closeTo(.4, 1e-7));
      expect(output.float32Values[count], 1);
      expect(output.float32Values.sublist(count * 2), body);
      body[0] = 99;
      expect(output.float32Values[count * 2], 2);
      values[count * 4] = 0;
      expect(
        () => profile.compose(
          MlTensor.float32([1, 5, 84, 84], values),
          ownBody: body,
        ),
        throwsStateError,
      );
      values[count * 3] = 0;
      expect(
        profile
            .compose(MlTensor.float32([1, 5, 84, 84], values), ownBody: body)
            .float32Values
            .first,
        0,
      );
      expect(
        () => profile.compose(
          MlTensor.float32([1, 3, 84, 84], List.filled(count * 3, 0)),
          ownBody: body,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'own-body is captured actor-local velocity and fixed goal, with no target input',
    () {
      final profile = TrainingVisualProfiles.forFamily(
        family: 'vehicle',
        mode: 'rgb',
      );
      final body = profile.ownBody(
        pose: PhysicsPose(
          position: const Vec3(0, 4, 0),
          rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
        ),
        velocity: const Vec3(2, 0, 0),
        angularVelocity: const Vec3(0, 3, 0),
      );
      expect(body[0], closeTo(0, 1e-6));
      expect(body[1], 0);
      expect(body[2], closeTo(2, 1e-6));
      expect(body.sublist(3), [3, 4, 1, 0, 1]);
      expect(() => body[0] = 1, throwsUnsupportedError);
      expect(
        () => profile.ownBody(
          pose: PhysicsPose(),
          velocity: const Vec3(10001, 0, 0),
          angularVelocity: Vec3.zero,
        ),
        throwsArgumentError,
      );
      final image = MlTensor.float32([
        1,
        3,
        84,
        84,
      ], List.filled(84 * 84 * 3, 0));
      expect(
        () => profile.compose(image, ownBody: [0, 0, 0, 0, 0, 1, 0, 0]),
        throwsStateError,
      );
      expect(
        () => profile.compose(image, ownBody: [0, 0, 0, 0, 0, 2, 0, 1]),
        throwsArgumentError,
      );
    },
  );
}
