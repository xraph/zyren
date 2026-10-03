import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/qualification/navigation_benchmark_capture.dart';

void main() {
  late Directory output;
  late Map<String, dynamic> report;
  setUp(() {
    output = Directory.systemTemp.createTempSync('navigation-capture-test-');
    report = {
      'passed': false,
      'error': 'Renderer failed during rotation.',
      'phases': [
        {
          'name': 'rotate',
          'completed': false,
          'samples': [
            {
              'loading': 2,
              'budgetLimited': true,
              'uploadedBytes': 128,
              'cloudReset': 'none',
            },
          ],
        },
      ],
    };
  });
  tearDown(() => output.deleteSync(recursive: true));

  Map<String, dynamic> read(String name) =>
      jsonDecode(File('${output.path}/$name.json').readAsStringSync())
          as Map<String, dynamic>;

  test('saves raw frames and summary before CPU capture completes', () async {
    final cpu = Completer<Map<String, dynamic>>();
    final saved = saveNavigationReport(
      output: output,
      report: report,
      captureCpu: () {
        expect(read('frames')['phases'][0]['samples'], hasLength(1));
        expect(read('summary')['phases'][0]['uploadedBytes'], 128);
        expect(read('summary')['passed'], isFalse);
        expect(read('summary')['cpuProfileStatus'], 'pending');
        return cpu.future;
      },
    );
    cpu.complete({'sampleCount': 12});
    await saved;
    expect(read('frames')['cpuSampleCount'], 12);
    expect(read('summary')['cpuProfileStatus'], 'captured');
    expect(read('cpu-samples')['sampleCount'], 12);
    expect(report['phases'][0]['samples'], hasLength(1));
  });

  test('CPU timeout retains the failed phase and returns a summary', () async {
    final summary = await saveNavigationReport(
      output: output,
      report: report,
      captureCpu: () => Completer<Map<String, dynamic>>().future,
      cpuTimeout: const Duration(milliseconds: 1),
    );
    expect(summary['passed'], isFalse);
    expect(summary['cpuProfileError'], 'TimeoutException');
    expect(summary['cpuProfileStatus'], 'unavailable');
    expect(read('frames')['phases'][0]['samples'], hasLength(1));
    expect(read('summary')['error'], report['error']);
    expect(File('${output.path}/cpu-samples.json').existsSync(), isFalse);
  });

  test('CPU failure does not change the benchmark outcome', () async {
    report['passed'] = true;
    final summary = await saveNavigationReport(
      output: output,
      report: report,
      captureCpu: () => throw StateError('CPU service unavailable'),
    );
    expect(summary['passed'], isTrue);
    expect(summary['cpuProfileError'], 'StateError');
    expect(read('frames')['cpuProfileStatus'], 'unavailable');
  });
}
