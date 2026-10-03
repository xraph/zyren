import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

Map<String, dynamic> fixtureJson() =>
    jsonDecode(File('test/fixtures/lstm_step.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('nested preprocessing data is copied and recursively immutable', () {
    final nested = <String, dynamic>{
      'normalization': {
        'mean': [0.1, 0.2],
      },
    };
    final json = fixtureJson()..['preprocessing'] = nested;
    final model = MlModelManifest.decode(jsonEncode(json));
    (nested['normalization']['mean'] as List)[0] = 100.0;
    expect(model.preprocessing['normalization']['mean'], [0.1, 0.2]);
    expect(
      () => model.preprocessing['normalization']['mean'][0] = 100,
      throwsUnsupportedError,
    );
    expect(
      () => model.preprocessing['normalization']['mean'] = [],
      throwsUnsupportedError,
    );
    expect(
      MlModelManifest.decode(model.encode()).preprocessing,
      model.preprocessing,
    );
  });
  test('fixture manifests round-trip with recurrent schema', () {
    for (final name in ['linear', 'lstm_step', 'cnn_step', 'typed_identity']) {
      final model = MlModelManifest.decode(
        File('test/fixtures/$name.json').readAsStringSync(),
      );
      expect(MlModelManifest.decode(model.encode()).encode(), model.encode());
    }
    expect(MlModelManifest.decode(jsonEncode(fixtureJson())).recurrent, {
      'hidden': 'next_hidden',
      'cell': 'next_cell',
    });
  });

  test('shape overflow is rejected before multiplication or allocation', () {
    expect(
      () => MlTensor(MlDtype.float32, [1 << 62, 1 << 62], Uint8List(0)),
      throwsArgumentError,
    );
    expect(
      () => MlTensor(MlDtype.int64, [-1], Uint8List(0)),
      throwsArgumentError,
    );
    expect(
      () => MlTensorSpec(
        name: 'x',
        dtype: MlDtype.float32,
        shape: [-1, -1],
        maxShape: [1 << 62, 1 << 62],
      ),
      throwsArgumentError,
    );
  });

  test('rejects file and external-data traversal including encoded paths', () {
    for (final path in [
      '../model.onnx',
      '/model.onnx',
      r'C:\model.onnx',
      r'a\..\model.onnx',
      'a/../../m.onnx',
      '%2e%2e/m.onnx',
      'a//m.onnx',
    ]) {
      expect(
        () => MlModelManifest.decode(
          jsonEncode(fixtureJson()..['modelFile'] = path),
        ),
        throwsFormatException,
      );
      expect(
        () => MlModelManifest.decode(
          jsonEncode(fixtureJson()..['externalData'] = [path]),
        ),
        throwsFormatException,
      );
    }
  });

  test('duplicate, unbounded and missing recurrent schema rejected', () {
    final duplicate = fixtureJson();
    (duplicate['inputs'] as List).add((duplicate['inputs'] as List).first);
    expect(
      () => MlModelManifest.decode(jsonEncode(duplicate)),
      throwsFormatException,
    );
    final missing = fixtureJson()..['recurrent'] = {'missing': 'next_hidden'};
    expect(
      () => MlModelManifest.decode(jsonEncode(missing)),
      throwsFormatException,
    );
    final unbounded = fixtureJson();
    (unbounded['inputs'] as List).first['maxShape'] = [-1, 4];
    expect(
      () => MlModelManifest.decode(jsonEncode(unbounded)),
      throwsFormatException,
    );
  });

  test('tensor storage and shapes remain owned and immutable', () {
    final bytes = Uint8List.fromList([1, 0]);
    final shape = [2];
    final tensor = MlTensor(MlDtype.bool, shape, bytes);
    shape[0] = 100;
    bytes[0] = 0;
    tensor.bytes[0] = 0;
    expect(tensor.shape, [2]);
    expect(tensor.boolValues, [true, false]);
    expect(() => tensor.shape[0] = 4, throwsUnsupportedError);
    expect(
      () => MlTensor(MlDtype.bool, [1], Uint8List.fromList([2])),
      throwsArgumentError,
    );
    expect(MlTensor.int64([2], [-7, 1 << 40]).int64Values, [-7, 1 << 40]);
    expect(MlTensor.float32([1], [double.nan]).isFinite, isFalse);
  });
}
