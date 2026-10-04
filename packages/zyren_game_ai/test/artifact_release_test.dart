import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';
import 'package:zyren_game_ai/artifact.dart';

void main() {
  for (final family in ['guard', 'vehicle']) {
    test('accepted $family files bind exact ONNX and reject tampering', () {
      final root = Directory('examples/game_lab/models').existsSync()
          ? 'examples/game_lab/models'
          : '../../examples/game_lab/models';
      final folder = '$root/$family';
      final manifest = File('$folder/bundle.json').readAsBytesSync();
      final files = {
        for (final name in ModelArtifact.fileNames)
          name: File('$folder/$name').readAsBytesSync(),
      };
      final artifact = ModelArtifact.decode(manifest, files);
      expect(artifact.family, family);
      expect(artifact.evaluation.accepted, isTrue);
      expect(artifact.fixedHz, 50);
      expect(artifact.evaluation.provider, 'python-onnxruntime-1.23.2-cpu');
      expect(
        artifact.evaluation.planHash,
        'deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd',
      );
      final original = Uint8List.fromList(manifest);
      final missingProof =
          jsonDecode(utf8.decode(files['provenance.json']!)) as Map;
      missingProof.remove('native_parity');
      final changed = Uint8List.fromList(utf8.encode(jsonEncode(missingProof)));
      final rehashed = jsonDecode(utf8.decode(original)) as Map;
      final row = (rehashed['files'] as List).cast<Map>().singleWhere(
        (e) => e['path'] == 'provenance.json',
      );
      row['sha256'] = sha256.convert(changed).toString();
      row['bytes'] = changed.length;
      expect(
        () => ModelArtifact.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(rehashed))),
          {...files, 'provenance.json': changed},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('native parity'),
          ),
        ),
      );
      manifest[0] ^= 1;
      expect(artifact.manifestBytes, original);
      final corrupt = Uint8List.fromList(files['actor.onnx']!)..[0] ^= 1;
      expect(
        () => ModelArtifact.decode(original, {...files, 'actor.onnx': corrupt}),
        throwsFormatException,
      );
      final other = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
      other['provider'] = 'gpu';
      expect(
        () => ModelArtifact.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(other))),
          files,
        ),
        throwsFormatException,
      );
    });
  }
}
