import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'resident allowance holds graph replacements beyond one allocation limit',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = backend.createResourceScope();
      try {
        expect(
          backend.capabilities.limits.maxResidentResourceBytes,
          256 * 1024 * 1024,
        );
        for (var i = 0; i < 3; i++) {
          await scope.createBuffer(
            BufferDescriptor(
              size: 32 * 1024 * 1024,
              usage: {BufferUsage.copyDestination},
            ),
          );
        }
        final stats = await backend.resourceStats();
        expect(stats.residentBytes, 96 * 1024 * 1024);
        expect(stats.liveAllocations, 3);
        for (var i = 3; i < 8; i++) {
          await scope.createBuffer(
            BufferDescriptor(
              size: 32 * 1024 * 1024,
              usage: {BufferUsage.copyDestination},
            ),
          );
        }
        await expectLater(
          scope.createBuffer(
            BufferDescriptor(size: 4, usage: {BufferUsage.copyDestination}),
          ),
          throwsA(
            isA<ResourceException>().having(
              (e) => e.code,
              'code',
              ResourceErrorCode.budgetExceeded,
            ),
          ),
        );
        expect(
          (await backend.resourceStats()).residentBytes,
          256 * 1024 * 1024,
        );
        expect((await backend.resourceStats()).liveAllocations, 8);
      } finally {
        await scope.close();
      }
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
