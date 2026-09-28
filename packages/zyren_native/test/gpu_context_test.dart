import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'host context drains accepted allocation and releases before closing',
    () async {
      final gate = Completer<void>();
      final calls = <int>[];
      final context = NativeGpuContext((operation, bytes, capacity) async {
        expect(operation, 'resource');
        final request = ByteData.sublistView(bytes);
        final opcode = request.getUint32(4, Endian.little);
        calls.add(opcode);
        if (opcode == 1) await gate.future;
        final result = Uint8List(capacity);
        final header = ByteData.sublistView(result);
        header.setUint32(0, 2, Endian.little);
        header.setUint64(8, request.getUint64(8, Endian.little), Endian.little);
        header.setUint64(16, capacity - 24, Endian.little);
        return NativeGpuReply.success(result);
      });
      final scope = context.createResourceScope();
      final allocation = scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      final closing = context.close();
      expect(() => context.createResourceScope(), throwsStateError);
      expect(() => context.createShaderCompiler(), throwsStateError);
      expect(() => context.createGraphCompiler(), throwsStateError);
      expect(calls, [1]);
      gate.complete();
      await expectLater(allocation, throwsStateError);
      await closing;
      expect(calls, [1, 6]);
      await context.close();
      expect(calls, [1, 6]);
    },
  );

  test('host resource errors preserve their typed native code', () async {
    final context = NativeGpuContext(
      (operation, bytes, capacity) async =>
          NativeGpuReply.failure(3, 'budget exhausted'),
    );
    final scope = context.createResourceScope();
    await expectLater(
      scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      ),
      throwsA(
        isA<ResourceException>().having(
          (e) => e.code,
          'code',
          ResourceErrorCode.budgetExceeded,
        ),
      ),
    );
    await context.close();
  });
}
