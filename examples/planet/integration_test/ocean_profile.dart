import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:planet/ocean/ocean_page.dart';

/// Application presentation pacing. The display's scanout timing is not exposed.
Future<Map<String, Object?>> profileOcean(
  OceanLabPageState state,
  int count,
) async {
  if (count < 1 || count > 1800) {
    throw ArgumentError.value(count, 'count', 'Expected 1..1800 frames.');
  }
  final samples = <PresentationSample>[];
  final waves = <double>[];
  final done = Completer<void>();
  final startTick = state.world!.host.clock.tick;
  var warmup = 0;
  final subscription = state.controller!.presentations.listen((sample) {
    if (warmup++ < 15 || sample.interval == null || samples.length >= count) {
      return;
    }
    samples.add(sample);
    final passes = state.world!.presentation!.controller!
        .diagnostics()
        .passes
        .where((p) => p.name.startsWith('waves'))
        .toList();
    if (passes.isNotEmpty && passes.every((p) => p.hostElapsed != null)) {
      waves.add(
        passes.fold(
          0.0,
          (sum, p) => sum + p.hostElapsed!.inMicroseconds / 1000,
        ),
      );
    }
    if (samples.length == count) done.complete();
  });
  try {
    await done.future.timeout(const Duration(seconds: 90));
  } finally {
    await subscription.cancel();
  }
  expect(samples.every((s) => s.frame.readbackBytes == 0), isTrue);
  final gpu = samples.map((s) => s.frame.gpuTime).nonNulls.toList();
  return {
    'scene': state.world!.definition.id,
    'sceneRevision': state.world!.definition.revision,
    'frames': samples.length,
    'warmupFrames': 15,
    'width': samples.last.frame.physicalSize.width,
    'height': samples.last.frame.physicalSize.height,
    'detail': state.world!.detail.name,
    'stockPreset': null,
    'presentationIntervalMs': percentiles(
      samples.map((s) => s.interval!.inMicroseconds / 1000),
    ),
    'sceneBuildCpuMs': percentiles(
      samples.map((s) => s.frame.cpuBuildTime.inMicroseconds / 1000),
    ),
    'sceneSubmitCpuMs': percentiles(
      samples.map((s) => s.frame.cpuSubmitTime.inMicroseconds / 1000),
    ),
    'renderSubmissionGpuMs': gpu.length == samples.length
        ? percentiles(gpu.map((v) => v.inMicroseconds / 1000))
        : null,
    'waveSubmissionHostMs': waves.length == samples.length
        ? percentiles(waves)
        : null,
    'wholeFrameGpuMs': null,
    'waterIncrementalCpuMs': null,
    'waterIncrementalGpuMs': null,
    'physicalGpuResidencyBytes': null,
    'readbackBytes': 0,
    'startTick': startTick,
    'endTick': state.world!.host.clock.tick,
    'diagnostics': state.world!.presentation!.controller!
        .diagnostics(
          patchCount:
              state.world!.presentation!.controller!.resources.patchCount,
          vertexCount:
              state.world!.presentation!.controller!.resources.vertexCount,
          passes: state.world!.presentation!.controller!.resources.measurements,
          lastQuery: state.world!.lastQuery,
        )
        .toJson(),
  };
}

Map<String, double> percentiles(Iterable<double> input) {
  final values = input.toList()..sort();
  double at(double fraction) =>
      values[((values.length - 1) * fraction).round()];
  return {'p50': at(.5), 'p95': at(.95), 'p99': at(.99)};
}
