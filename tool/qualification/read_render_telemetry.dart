import 'dart:convert';
import 'dart:io';
// This workspace tool uses Flutter's bundled VM service client.
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError(
      'Pass a private VM connection file and an output JSON path.',
    );
  }
  final connection = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final service = await vmServiceConnectUri(connection['wsUri'] as String);
  try {
    final vm = await service.getVM();
    for (final isolate in vm.isolates ?? []) {
      final state = await service.getIsolate(isolate.id!);
      if (!(state.extensionRPCs ?? []).contains('ext.planet.renderStatus')) {
        continue;
      }
      final result = await service.callServiceExtension(
        'ext.planet.renderStatus',
        isolateId: isolate.id,
      );
      final data = result.json!;
      File(args[1]).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(data)}\n',
      );
      final samples = data['samples'] as List;
      final span = samples.length < 2
          ? 0
          : (samples.last['atUs'] as int) - (samples.first['atUs'] as int);
      print(
        jsonEncode({
          'status': data['status'],
          'issueCode': data['issueCode'],
          'preset': data['preset'],
          'moonlight': data['moonlight'],
          'night': data['night'],
          'cloudSize': data['cloudSize'],
          'cloudFrames': data['cloudFrames'],
          'tiles': data['visibleTiles'],
          'loading': data['loadingTiles'],
          'samples': samples.length,
          'presentedFps': span == 0 || data['status'] != 'SceneReady'
              ? null
              : (samples.length - 1) * 1e6 / span,
        }),
      );
      return;
    }
    throw StateError('The running app has no rendering telemetry extension.');
  } finally {
    await service.dispose();
  }
}
