import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 25),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final file = File(
      Platform.environment['GAME_BENCHMARK_RECEIPT'] ??
          'build/qualification/benchmark.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        data ??
            {
              'status': 'failed',
              'diagnostics': ['Missing native receipt'],
            },
      ),
    );
  },
);
