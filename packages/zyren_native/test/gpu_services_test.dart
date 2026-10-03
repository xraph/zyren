import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'failed native frame snapshots decode while GPU commands stay rejected',
    () async {
      final profile = <String, Object?>{
        'status': 'failed',
        'cpuPrepareNs': 1000,
        'cpuEncodeNs': 2000,
        'cpuCompletionWaitNs': 2000000000,
        'gpuTimeNs': null,
        'gpuTimeSource': 'unavailable',
        'submissionCount': 1,
        'drawPreparationBuffers': 1,
        'drawPreparationBindGroups': 1,
        'drawCacheReuses': null,
        'uploadBytes': 0,
        'passes': {
          'scene': {'executed': true, 'gpuTimeNs': null},
        },
        'resources': {'submissionCount': 0, 'gpuTimeNs': null},
      };
      final gpu = NativeGpuServices.withTransport((
        kind,
        bytes,
        capacity,
      ) async {
        expect(kind, NativeGpuCommand.graph);
        final request = jsonDecode(utf8.decode(bytes)) as Map;
        return NativeGpuReply.success(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'request': request['request'],
                if ((request['command'] as Map)['operation'] == 'frameProfile')
                  'result': profile
                else
                  'error': {
                    'code': 'deviceFailed',
                    'message': 'Recreate the failed native device',
                  },
              }),
            ),
          ),
        );
      });
      final decoded = await gpu.frameProfile();
      expect(decoded.toJson(), profile);
      expect(decoded.status, 'failed');
      expect(decoded.gpuTime, isNull);
      expect(decoded.passes['scene']!.gpuTimeNs, isNull);
      expect(decoded.cpuCompletionWaitNs, 2000000000);
      await expectLater(
        gpu.graphStats(),
        throwsA(
          isA<GraphException>().having(
            (error) => error.code,
            'code',
            GraphErrorCode.deviceFailed,
          ),
        ),
      );
      await gpu.close();
    },
  );

  test(
    'transport scopes drain pending creation before release and close',
    () async {
      final gate = Completer<NativeGpuReply>();
      final opcodes = <int>[];
      final gpu = NativeGpuServices.withTransport((
        kind,
        packet,
        capacity,
      ) async {
        expect(kind, NativeGpuCommand.resource);
        final input = ByteData.sublistView(packet);
        final opcode = input.getUint32(4, Endian.little);
        opcodes.add(opcode);
        if (opcode == 1) return gate.future;
        final response = ByteData(capacity)
          ..setUint32(0, 2, Endian.little)
          ..setUint64(8, input.getUint64(8, Endian.little), Endian.little);
        return NativeGpuReply.success(response.buffer.asUint8List());
      });
      final first = gpu.createResourceScope(),
          second = gpu.createResourceScope();
      final pending = first.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      final rejected = expectLater(pending, throwsStateError);
      final closing = gpu.close();
      expect(first.isClosed, isTrue);
      expect(second.isClosed, isTrue);
      expect(() => gpu.createGraphCompiler(), throwsStateError);
      final response = ByteData(56)
        ..setUint32(0, 2, Endian.little)
        ..setUint64(8, 1, Endian.little)
        ..setUint64(16, 32, Endian.little);
      gate.complete(NativeGpuReply.success(response.buffer.asUint8List()));
      await rejected;
      await closing;
      expect(opcodes, [1, 6]);
      expect(gpu.close(), same(closing));
    },
  );

  test(
    'typed resource failures and oversized transport replies are preserved',
    () async {
      var malformed = false;
      final gpu = NativeGpuServices.withTransport(
        (kind, bytes, capacity) async => malformed
            ? NativeGpuReply.success(Uint8List(capacity + 1))
            : NativeGpuReply.failure(3, 'budget exceeded'),
      );
      final scope = gpu.createResourceScope();
      final description = BufferDescriptor(
        size: 16,
        usage: {BufferUsage.uniform},
      );
      await expectLater(
        scope.createBuffer(description),
        throwsA(
          isA<ResourceException>().having(
            (e) => e.code,
            'code',
            ResourceErrorCode.budgetExceeded,
          ),
        ),
      );
      malformed = true;
      await expectLater(scope.createBuffer(description), throwsStateError);
      await gpu.close();
    },
  );
}
