import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'retirement tickets coordinate shared allocations and preserve borrowers',
    () async {
      final backend = await NativeBackend.create();
      final owner = backend.createResourceScope();
      final borrower = backend.createResourceScope();
      try {
        final texture = await owner.createTexture(
          TextureDescriptor(
            width: 16,
            height: 16,
            format: TextureFormat.rgba16Float,
            usage: {TextureUsage.sampled},
          ),
        );
        await borrower.retain(texture);
        final first = await texture.watchRetirement();
        final second = await texture.watchRetirement();
        await owner.close();
        expect(await first.poll(), isFalse);
        await borrower.close();
        expect(await Future.wait([first.poll(), first.poll()]), [true, true]);
        expect((await backend.resourceStats()).liveAllocations, 1);
        expect(await second.poll(), isTrue);
        expect(await first.poll(), isTrue);
        expect((await backend.resourceStats()).liveAllocations, 0);
      } finally {
        await borrower.close();
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
