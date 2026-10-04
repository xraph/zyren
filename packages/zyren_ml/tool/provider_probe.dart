import 'dart:convert';
import 'dart:io';

import 'package:zyren_ml/zyren_ml.dart';

MlTensorMap tensors(Map<String, dynamic> values) => values.map(
  (key, value) => MapEntry(
    key,
    MlTensor.float32(
      (value['shape'] as List).cast<int>(),
      (value['values'] as List).cast<num>(),
    ),
  ),
);

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: provider_probe.dart <model.json> <reference.jsonl>');
    exitCode = 64;
    return;
  }
  final file = File(arguments[0]);
  final model = MlModelManifest.decode(await file.readAsString());
  final reference = File(arguments[1]);
  if (await reference.length() > 32 * 1024 * 1024) {
    throw FormatException('Reference exceeds 32MiB.');
  }
  final lines = await reference.readAsLines();
  if (lines.isEmpty ||
      lines.length > 4096 ||
      lines.any((line) => line.length > 262144)) {
    throw FormatException('Reference exceeds row or line bounds.');
  }
  MlProviderProbeStep step(String line) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    return MlProviderProbeStep(
      inputs: tensors(row['inputs'] as Map<String, dynamic>),
      referenceOutputs: tensors(row['outputs'] as Map<String, dynamic>),
      resetState: row['reset'] == true,
    );
  }

  final first = step(lines.first);
  final report = await const MlProviderProbe().probe(
    model: model,
    resolver: (path) => File('${file.parent.path}/$path').readAsBytes(),
    inputs: first.inputs,
    referenceOutputs: first.referenceOutputs,
    provider: 'coreml',
    sequence: lines.map(step),
  );
  final owners = const MlRuntime().diagnostics;
  stdout.writeln(
    jsonEncode({
      'model_sha256': model.sha256,
      'runtime': MlRuntime.runtimeVersion,
      'requested_provider': report.requestedProvider,
      'actual_provider': report.actualProvider,
      'status': report.status.name,
      'message': report.message,
      'partition': report.partition?.kernels,
      'numerical_verified': report.numericalProbeVerified,
      'sequence_steps': report.sequenceSteps,
      'timing_benefit': report.timingBenefitVerified,
      'selection_issued': report.selection != null,
      'accelerated_hardware': report.acceleratedHardware,
      'load_us': report.modelLoad?.inMicroseconds,
      'cold_us': report.coldRun?.inMicroseconds,
      'warm_us': report.warmRun?.inMicroseconds,
      'cpu_median_us': report.cpuRoundTripMedian?.inMicroseconds,
      'coreml_median_us': report.providerRoundTripMedian?.inMicroseconds,
      'cpu_p95_us': report.cpuRoundTripP95?.inMicroseconds,
      'coreml_p95_us': report.providerRoundTripP95?.inMicroseconds,
      'live_sessions': owners.liveSessions,
      'live_results': owners.liveResults,
      'active_runs': owners.activeRuns,
    }),
  );
}
