import 'dart:async';
import 'dart:convert';
import 'dart:io';
// The workspace resolves Flutter's VM service client.
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Pass the private VM connection file, output directory and variant.',
    );
  }
  final output = Directory(args[1]);
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError(
      'Use an empty output directory to preserve prior measurements.',
    );
  }
  output.createSync(recursive: true);
  final raw = File(args[0]).readAsStringSync().trim();
  Object? connection;
  try {
    connection = jsonDecode(raw);
  } catch (_) {
    connection = raw;
  }
  final address = connection is Map
      ? connection['wsUri'] ?? connection['uri']
      : connection;
  final uri = Uri.parse(address as String);
  final ws = uri.scheme.startsWith('ws')
      ? uri
      : uri.replace(
          scheme: uri.scheme == 'https' ? 'wss' : 'ws',
          path: '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws',
        );
  final service = await vmServiceConnectUri(ws.toString());
  try {
    String? isolateId;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (isolateId == null && DateTime.now().isBefore(deadline)) {
      for (final ref in (await service.getVM()).isolates ?? []) {
        final isolate = await service.getIsolate(ref.id!);
        if ((isolate.extensionRPCs ?? []).contains(
          'ext.planet.navigationBenchmark',
        )) {
          isolateId = ref.id;
          break;
        }
      }
      if (isolateId == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (isolateId == null) {
      throw StateError('Navigation benchmark extension unavailable.');
    }
    final start = (await service.getVMTimelineMicros()).timestamp!;
    await service.clearCpuSamples(isolateId);
    await service.callServiceExtension(
      'ext.planet.navigationBenchmark',
      isolateId: isolateId,
      args: {'command': 'start', 'variant': args[2]},
    );
    String? previousStage;
    final timeout = DateTime.now().add(const Duration(minutes: 15));
    while (DateTime.now().isBefore(timeout)) {
      final response = await service.callServiceExtension(
        'ext.planet.navigationBenchmark',
        isolateId: isolateId,
      );
      final data = response.json!;
      if (data['stage'] != previousStage) {
        previousStage = data['stage'] as String?;
        stdout.writeln(previousStage);
      }
      if (data['running'] == false && data['result'] is Map) {
        final report = Map<String, dynamic>.from(data['result'] as Map);
        final end = (await service.getVMTimelineMicros()).timestamp!;
        try {
          final cpu = await service.getCpuSamples(
            isolateId,
            start,
            end - start,
          );
          File(
            '${output.path}/cpu-samples.json',
          ).writeAsStringSync(jsonEncode(cpu.json));
          report['cpuSampleCount'] = cpu.sampleCount;
        } catch (error) {
          report['cpuProfileError'] = error.runtimeType.toString();
        }
        File(
          '${output.path}/frames.json',
        ).writeAsStringSync(jsonEncode(report));
        for (final phase in report['phases'] as List) {
          final samples = phase.remove('samples') as List;
          phase['framesWhileLoading'] = samples
              .where((s) => (s['loading'] as int) > 0)
              .length;
          phase['framesBudgetLimited'] = samples
              .where((s) => s['budgetLimited'] == true)
              .length;
          phase['uploadedBytes'] = samples.fold<int>(
            0,
            (sum, s) => sum + (s['uploadedBytes'] as int),
          );
          phase['cloudHistoryResets'] = samples
              .where((s) => s['cloudReset'] != 'none')
              .length;
        }
        File('${output.path}/summary.json').writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
        stdout.writeln(jsonEncode(report));
        if (report['passed'] != true) exitCode = 1;
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw TimeoutException('The live navigation benchmark did not finish.');
  } finally {
    await service.dispose();
  }
}
