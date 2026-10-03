import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_device_report.dart';

void main() {
  test('exports interrupted samples without claiming CPU capture', () async {
    final output = await Directory.systemTemp.createTemp('navigation-export-');
    addTearDown(() => output.delete(recursive: true));
    await saveNavigationDeviceReport(output, 'ipad-1', {
      'passed': false,
      'phases': [
        {
          'name': 'rotate',
          'completed': false,
          'samples': [
            {'atUs': 5},
          ],
        },
      ],
    });
    final file = File('${output.path}/ipad-1.json');
    final raw = await file.readAsString();
    final report = jsonDecode(raw) as Map;
    expect(report['passed'], false);
    expect(report['cpuProfileStatus'], 'unavailable');
    expect(report['runId'], 'ipad-1');
    expect((report['phases'] as List).single['samples'], [
      {'atUs': 5},
    ]);
    expect(output.listSync(), hasLength(1));
    await expectLater(
      saveNavigationDeviceReport(output, 'ipad-1', {}),
      throwsStateError,
    );
    expect(await file.readAsString(), raw);
    await expectLater(
      saveNavigationDeviceReport(output, '../escape', {}),
      throwsArgumentError,
    );
    expect(output.listSync(), hasLength(1));
  });
}
