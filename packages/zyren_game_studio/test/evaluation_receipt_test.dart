import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_studio/training.dart';

void main() {
  test(
    'actual passed checkpoint report cannot bind to another ONNX artifact',
    () async {
      final path = Directory('packages/zyren_game_studio').existsSync()
          ? 'packages/zyren_game_studio/test/fixtures/passed-checkpoint-evaluation-v4.json'
          : 'test/fixtures/passed-checkpoint-evaluation-v4.json';
      final raw = File(path).readAsBytesSync(),
          data = jsonDecode(File(path).readAsStringSync()) as Map;
      const expected =
          '32c482493591075e463f4d6433c585cbf5917e360aad7c06a8a8ea56e42fc0a9';
      expect(sha256.convert(raw).toString(), expected);
      final c = (data['plan']['cases'] as List).firstWhere(
        (c) => c['family'] == 'guard',
      );
      Future<TrainingEvaluation> read(String model) =>
          EvaluationReceiptReader().readFamily(
            path,
            receiptHash: expected,
            family: 'guard',
            modelHash: model,
            observationHash: c['scenario']['observation_schema_hash'],
            actionHash: c['scenario']['action_schema_hash'],
          );
      expect(
        (await read(data['family_model_hashes']['guard'])).accepted,
        isTrue,
      );
      await expectLater(read('0' * 64), throwsFormatException);
    },
  );
  test(
    'actual T4 perfect-success receipt remains failed for collision gate',
    () async {
      final path = Directory('packages/zyren_game_studio').existsSync()
          ? 'packages/zyren_game_studio/test/fixtures/failed-evaluation-v3.json'
          : 'test/fixtures/failed-evaluation-v3.json';
      final raw = File(path).readAsBytesSync();
      expect(
        sha256.convert(raw).toString(),
        'f6e2986641e31f1552cfddef5a4a5c768a789d0610f94b0ad4c19fff1f51d22f',
      );
      final data = jsonDecode(utf8.decode(raw)) as Map;
      final c = (data['plan']['cases'] as List).firstWhere(
        (c) => c['family'] == 'vehicle',
      );
      Future<TrainingEvaluation> read(String p, String hash) =>
          EvaluationReceiptReader().readFamily(
            p,
            receiptHash: hash,
            family: 'vehicle',
            modelHash: data['family_model_hashes']['vehicle'],
            observationHash: c['scenario']['observation_schema_hash'],
            actionHash: c['scenario']['action_schema_hash'],
          );
      final result = await read(path, sha256.convert(raw).toString());
      expect(result.accepted, isFalse);
      expect((data['metrics']['vehicle'] as Map)['success_rate'], 1);
      final dir = Directory.systemTemp.createTempSync('evaluation-read-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Future<void> reject(String source) async {
        final file = File('${dir.path}/altered.json')
          ..writeAsStringSync(source);
        await expectLater(
          read(file.path, sha256.convert(utf8.encode(source)).toString()),
          throwsA(anything),
        );
      }

      await reject(
        utf8.decode(raw).replaceFirst('"status":"failed"', '"status":"passed"'),
      );
      final altered = jsonDecode(utf8.decode(raw)) as Map;
      (altered['episodes'] as List).removeLast();
      await reject(jsonEncode(altered));
      await expectLater(
        EvaluationReceiptReader().readFamily(
          path,
          receiptHash: sha256.convert(raw).toString(),
          family: 'vehicle',
          modelHash: '0' * 64,
          observationHash: c['scenario']['observation_schema_hash'],
          actionHash: c['scenario']['action_schema_hash'],
        ),
        throwsA(anything),
      );
    },
  );
}
