import 'dart:io';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

void main() {
  final model = MlModelManifest.decode(
    File('test/fixtures/linear.json').readAsStringSync(),
  );
  final inputs = {
    'observation': MlTensor.float32([1, 4], [1, 2, 3, 4]),
  };
  const probe = MlProviderProbe();
  test(
    'CPU exact graph probe reports load/cold/warm and numerical parity',
    () async {
      final report = await probe.probe(
        model: model,
        resolver: (path) => File('test/fixtures/$path').readAsBytes(),
        inputs: inputs,
        referenceOutputs: {
          'action': MlTensor.float32([1, 2], [30.5, 1.5]),
        },
      );
      expect(report.status, MlRunStatus.ok, reason: report.message);
      expect(report.actualProvider, 'cpu');
      expect(report.unsupportedOperators, isEmpty);
      expect(report.numericalProbeVerified, isTrue);
      expect(report.modelLoad, isNotNull);
      expect(report.coldRun, isNotNull);
      expect(report.warmRun, isNotNull);
      expect(report.nativeArenaBytes, isNull);
    },
  );
  test('unqualified providers fail without silently selecting CPU', () async {
    var resolved = false;
    final report = await probe.probe(
      model: model,
      resolver: (_) async {
        resolved = true;
        return File('test/fixtures/linear.onnx').readAsBytes();
      },
      inputs: inputs,
      provider: 'coreml',
    );
    expect(report.status, MlRunStatus.unsupported);
    expect(report.actualProvider, isNull);
    expect(report.unsupportedOperators, isNull);
    expect(resolved, isFalse);
  });
  test(
    'successful CPU loading does not pass an incorrect numerical reference',
    () async {
      final report = await probe.probe(
        model: model,
        resolver: (path) => File('test/fixtures/$path').readAsBytes(),
        inputs: inputs,
        referenceOutputs: {
          'action': MlTensor.float32([1, 2], [0, 0]),
        },
      );
      expect(report.status, MlRunStatus.failed);
      expect(report.numericalProbeVerified, isFalse);
    },
  );
}
