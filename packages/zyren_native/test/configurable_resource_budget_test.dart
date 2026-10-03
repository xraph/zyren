import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native resource budgets reject shrink atomically and release allocations',
    () async {
      const mib = 1024 * 1024;
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      Future<GpuResource<Buffer>> allocate(int size) => scope.createBuffer(
        BufferDescriptor(size: size, usage: {BufferUsage.storage}),
      );
      try {
        await backend.configureResourceBudget(16 * mib);
        await allocate(12 * mib);
        await expectLater(allocate(8 * mib), throwsA(isA<ResourceException>()));
        await backend.configureResourceBudget(32 * mib);
        expect(backend.capabilities.limits.maxResidentResourceBytes, 32 * mib);
        await allocate(8 * mib);
        await expectLater(
          backend.configureResourceBudget(16 * mib),
          throwsA(isA<ResourceException>()),
        );
        await allocate(8 * mib);
        expect((await backend.resourceStats()).residentBytes, 28 * mib);
        expect(backend.capabilities.limits.maxResidentResourceBytes, 32 * mib);
        for (final invalid in [0, 16 * mib - 1, 1024 * mib + 1]) {
          await expectLater(
            backend.configureResourceBudget(invalid),
            throwsRangeError,
          );
        }
      } finally {
        await scope.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.configureResourceBudget(16 * mib);
        await backend.close();
      }
    },
  );
}
