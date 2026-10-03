import 'dart:convert';
import 'dart:typed_data';

Map<String, Object> deviceInfoReply(
  Map arguments, {
  List<int> samples = const [1, 4],
}) {
  final request =
      jsonDecode(
            utf8.decode((arguments['bytes'] ?? arguments['data']) as Uint8List),
          )
          as Map;
  final operation = (request['command'] as Map)['operation'];
  final Map<String, Object?> result;
  if (operation == 'deviceInfo') {
    result = {
      'backend': 'test',
      'adapterName': 'test adapter',
      'sampleCounts': samples,
    };
  } else if (operation == 'frameProfile') {
    result = {
      'status': 'complete',
      'cpuPrepareNs': 1000,
      'cpuEncodeNs': 2000,
      'cpuCompletionWaitNs': 3000,
      'gpuTimeNs': null,
      'gpuTimeSource': 'unavailable',
      'submissionCount': 1,
      'drawPreparationBuffers': 0,
      'drawPreparationBindGroups': 0,
      'drawCacheReuses': null,
      'uploadBytes': 0,
      'passes': {
        'scene': {'executed': true, 'gpuTimeNs': null},
      },
      'resources': {},
    };
  } else {
    throw StateError('Unexpected GPU command');
  }
  final data = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'request': request['request'],
        'result': result,
      }),
    ),
  );
  return {
    'status': 0,
    if (arguments.containsKey('bytes')) 'bytes': data,
    'data': data,
  };
}
