import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

Uint8List reply({int version = 1, int request = 42, bool error = false}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': version,
          'request': request,
          if (error)
            'error': {'code': 'deviceFailed', 'message': 'Recreate the device'}
          else
            'result': {
              'status': 'complete',
              'cpuPrepareNs': 1000,
              'cpuEncodeNs': 2000,
              'cpuCompletionWaitNs': 3000,
              'gpuTimeNs': null,
              'gpuTimeSource': 'unavailable',
              'submissionCount': 1,
              'drawPreparationBuffers': 0,
              'drawPreparationBindGroups': 0,
              'uploadBytes': 0,
              'passes': {
                'scene': {'executed': true, 'gpuTimeNs': null},
              },
              'resources': {},
            },
        }),
      ),
    );

void main() {
  test(
    'embedded native frame profile preserves timing and unknown GPU data',
    () {
      final profile = NativeGpuServices.decodeFrameProfile(
        reply(),
        frameId: 42,
      );
      expect(profile.cpuPrepareNs, 1000);
      expect(profile.cpuEncodeNs, 2000);
      expect(profile.cpuCompletionWaitNs, 3000);
      expect(profile.gpuTimeNs, isNull);
      expect(profile.gpuTimeSource, 'unavailable');
      expect(profile.passes['scene']!.executed, isTrue);
    },
  );
  test('mismatched frame IDs and protocol versions reject', () {
    for (final bytes in [reply(request: 41), reply(version: 2)]) {
      expect(
        () => NativeGpuServices.decodeFrameProfile(bytes, frameId: 42),
        throwsStateError,
      );
    }
  });
  test('empty or oversized profiles reject before decoding', () {
    for (final bytes in [Uint8List(0), Uint8List(256 * 1024 + 1)]) {
      expect(
        () => NativeGpuServices.decodeFrameProfile(bytes, frameId: 42),
        throwsStateError,
      );
    }
  });
  test('native graph error stays typed', () {
    expect(
      () =>
          NativeGpuServices.decodeFrameProfile(reply(error: true), frameId: 42),
      throwsA(
        isA<GraphException>().having(
          (e) => e.code,
          'code',
          GraphErrorCode.deviceFailed,
        ),
      ),
    );
  });
}
