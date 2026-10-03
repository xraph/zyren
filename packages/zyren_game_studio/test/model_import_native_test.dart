import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_studio/model_library.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_game_ai/test/policy_test.dart' show PolicyFixture;

void main() {
  test(
    'model import validates actual isolated ONNX load and corrupt bytes never activate',
    () async {
      final root = Directory.current.path.endsWith('zyren_game_studio')
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final manifest = MlModelManifest.decode(
        await File(
          '$root/packages/zyren_ml/test/fixtures/lstm_step.json',
        ).readAsString(),
      );
      final bytes = await File(
        '$root/packages/zyren_ml/test/fixtures/lstm_step.onnx',
      ).readAsBytes();
      final fixture = PolicyFixture();
      final contract = fixture.contract(manifest, ActionDecoder.character());
      final cache = MlModelCache(resolver: (_) async => bytes);
      final importer = ModelImport(
        cache: cache,
        observation: contract.observation,
        action: contract.decoder.spec,
      );
      final result = await importer.validate(contract);
      expect(result.compatible, isTrue);
      expect(result.accepted, isFalse);
      expect(cache.diagnostics.leaseReferences, 0);
      expect(cache.diagnostics.residentModels, 1);
      await cache.close();
      expect((await cache.worker.diagnostics()).liveSessions, 0);
      final corrupt = MlModelCache(
        resolver: (_) async => Uint8List.fromList([1, 2, 3]),
      );
      try {
        await expectLater(
          ModelImport(
            cache: corrupt,
            observation: contract.observation,
            action: contract.decoder.spec,
          ).validate(contract),
          throwsA(isA<MlLoadException>()),
        );
        expect(corrupt.diagnostics.leaseReferences, 0);
      } finally {
        await corrupt.close();
      }
      expect((await cache.worker.diagnostics()).liveSessions, 0);
    },
  );
}
