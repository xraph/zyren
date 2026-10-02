import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final path = Platform.environment['ZYREN_QUALIFICATION_OUTPUT'];
    if (path == null || path.isEmpty) {
      throw StateError(
        'Set ZYREN_QUALIFICATION_OUTPUT to a local result file.',
      );
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    );
  },
);
