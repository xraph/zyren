import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
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
