import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

void main() {
  test(
    'two native models with the same filename resolve by their immutable manifests',
    () async {
      MlModelManifest model(String id) => MlModelManifest.decode(
        jsonEncode(
          (jsonDecode(File('test/fixtures/$id.json').readAsStringSync())
                as Map<String, dynamic>)
            ..['modelFile'] = 'actor.onnx',
        ),
      );
      final linear = model('linear'), recurrent = model('lstm_step');
      final paths = {linear.sha256: 'linear', recurrent.sha256: 'lstm_step'};
      final resolved = <String>[];
      final cache = MlModelCache(
        manifestResolver: (manifest) async {
          resolved.add(manifest.sha256);
          expect(manifest.modelFile, 'actor.onnx');
          return File(
            'test/fixtures/${paths[manifest.sha256]}.onnx',
          ).readAsBytes();
        },
      );
      try {
        final first = await cache.acquire(linear);
        final second = await cache.acquire(recurrent);
        expect(resolved, [linear.sha256, recurrent.sha256]);
        expect(cache.diagnostics.residentModels, 2);
        expect((await cache.worker.diagnostics()).liveSessions, 2);
        await cache.release(first);
        await cache.release(second);
      } finally {
        await cache.close();
      }
      expect((await cache.worker.diagnostics()).liveSessions, 0);
    },
  );
  test(
    'resolver choice is explicit and returned bytes still require their hash',
    () async {
      expect(() => MlModelCache(), throwsArgumentError);
      expect(
        () => MlModelCache(
          resolver: (_) async => throw StateError('unused'),
          manifestResolver: (_) async => throw StateError('unused'),
        ),
        throwsArgumentError,
      );
      final model = MlModelManifest.decode(
        File('test/fixtures/linear.json').readAsStringSync(),
      );
      final cache = MlModelCache(
        manifestResolver: (_) =>
            File('test/fixtures/lstm_step.onnx').readAsBytes(),
      );
      try {
        await expectLater(
          cache.acquire(model),
          throwsA(
            isA<MlLoadException>().having(
              (e) => e.status,
              'status',
              MlRunStatus.invalid,
            ),
          ),
        );
        expect(cache.diagnostics.residentModels, 0);
      } finally {
        await cache.close();
      }
    },
  );
}
