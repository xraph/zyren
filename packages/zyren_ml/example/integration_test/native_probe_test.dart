import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_ml_probe/probe.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real CPU native mobile fixture parity and zero live handles', (
    tester,
  ) async {
    final receipt = await tester.runAsync(runNativeProbe);
    expect(receipt!['status'], 'passed');
    expect(receipt['completed_runs'], 1032);
    expect(receipt['recurrent_steps'], 1000);
    expect(receipt['live_sessions'], 0);
    expect(receipt['live_results'], 0);
    expect(receipt['worker_isolate'], isNotNull);
    binding.reportData = receipt;
    // Small receipt captured in device logs, with no tensor or private data.
    print('ZYREN_ML_DEVICE_RECEIPT=${jsonEncode(receipt)}');
  });
}
