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
  if ((request['command'] as Map)['operation'] != 'deviceInfo') {
    throw StateError('Unexpected GPU command');
  }
  return {
    'status': 0,
    if (arguments.containsKey('bytes'))
      'bytes': _deviceBytes(arguments, samples),
    'data': Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'request': request['request'],
          'result': {
            'backend': 'test',
            'adapterName': 'test adapter',
            'sampleCounts': samples,
          },
        }),
      ),
    ),
  };
}

Uint8List _deviceBytes(Map arguments, List<int> samples) {
  final request =
      jsonDecode(utf8.decode(arguments['bytes'] as Uint8List)) as Map;
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'request': request['request'],
        'result': {
          'backend': 'test',
          'adapterName': 'test adapter',
          'sampleCounts': samples,
        },
      }),
    ),
  );
}
