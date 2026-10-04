import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'artifact_test.dart' show CodecFixture, jsonBytes, digest;

// Byte-only codec cases, never published or loaded as a trained ONNX model.
CodecFixture visualFixture(String mode) {
  final f = CodecFixture();
  final profile = TrainingVisualProfiles.forFamily(family: 'guard', mode: mode);
  final model = jsonDecode(utf8.decode(f.files['model.json']!)) as Map;
  model['preprocessing'] = {
    'normalization': 'embedded-camera-body-affine-v1',
    'sourceHash': 'a' * 64,
    'visualProfile': profile.toJson(),
  };
  (model['inputs'] as List).first['shape'] = [-1, profile.width];
  (model['inputs'] as List).first['maxShape'] = [64, profile.width];
  f.files['model.json'] = jsonBytes(model);
  f.files['observation.json'] = jsonBytes(profile.spec.toJson());
  f.files['normalization.json'] = jsonBytes({
    'schema_version': 1,
    'mode': 'embedded-camera-body-affine-v1',
    'camera_width': profile.imageWidth,
    'mean': List.filled(8, 0.0),
    'scale': List.filled(8, 1.0),
    'source_hash': 'a' * 64,
  });
  final report = jsonDecode(utf8.decode(f.files['evaluation.json']!)) as Map;
  for (final c in report['plan']['cases'] as List) {
    if (c['family'] == 'guard') {
      c['scenario']['observation_schema_hash'] = profile.spec.hash;
    }
  }
  report['plan_hash'] = digest(jsonBytes(report['plan']));
  f.files['evaluation.json'] = jsonBytes(report);
  f.bundle['family'] = profile.artifactFamily;
  f.bundle['observation_schema_hash'] = profile.spec.hash;
  f.bundle['evaluation_report_hash'] = digest(f.files['evaluation.json']!);
  f.bundle['evaluation_plan_hash'] = report['plan_hash'];
  (f.bundle['policy'] as Map)['max_hold_ticks'] = 2;
  return f;
}

void main() {
  test(
    'compact visual ABI validates but unregistered quality plans stay closed',
    () {
      for (final mode in ['rgb', 'depth', 'combined']) {
        final f = visualFixture(mode);
        expect(
          visualModelEvaluationPlanHashes[mode]!.contains(
            f.bundle['evaluation_plan_hash'],
          ),
          isFalse,
        );
        expect(
          () => ModelArtifact.decode(f.manifest, f.files),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'gate',
              contains('not registered'),
            ),
          ),
        );
      }
    },
  );
  test('camera/body header and compact affine metadata reject tampering', () {
    final f = visualFixture('depth');
    final model = jsonDecode(utf8.decode(f.files['model.json']!)) as Map;
    model['preprocessing']['visualProfile']['goal'] = [0.0, 1.0];
    f.files['model.json'] = jsonBytes(model);
    expect(
      () => ModelArtifact.decode(f.manifest, f.files),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'header',
          contains('header'),
        ),
      ),
    );
    final wrong = visualFixture('combined');
    final norm =
        jsonDecode(utf8.decode(wrong.files['normalization.json']!)) as Map;
    norm['camera_width'] = 84 * 84 * 3;
    wrong.files['normalization.json'] = jsonBytes(norm);
    expect(
      () => ModelArtifact.decode(wrong.manifest, wrong.files),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'ABI', contains('ABI')),
      ),
    );
  });
}
