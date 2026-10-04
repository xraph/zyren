import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'visual header pins exact mode, camera pose and raw own-body layout',
    () {
      for (final family in ['guard', 'vehicle']) {
        for (final mode in ['rgb', 'depth', 'combined']) {
          final profile = TrainingVisualProfiles.forFamily(
            family: family,
            mode: mode,
          );
          expect(
            TrainingVisualProfiles.fromJson(profile.toJson()).configurationHash,
            profile.configurationHash,
          );
          final wrong = <String, Object?>{
            ...profile.toJson(),
            'body_fields': ['height', 'localVelocityX'],
          };
          expect(
            () => TrainingVisualProfiles.fromJson(wrong),
            throwsFormatException,
          );
          final extra = <String, Object?>{
            ...profile.toJson(),
            'teacher_target': [1, 2, 3],
          };
          expect(
            () => TrainingVisualProfiles.fromJson(extra),
            throwsFormatException,
          );
        }
      }
    },
  );
}
