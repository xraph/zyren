import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/src/bindings.dart' as native;

const options = BufferDecodeOptions(
  encoding: BufferEncoding.meshopt,
  count: 3,
  stride: 12,
);
Future<Uint8List> fixture() =>
    File('../../test_assets/compression/triangle.meshopt').readAsBytes();

void main() {
  const decoder = NativeBufferDecoder();
  test(
    'CPU buffer decoder snapshots input and creates no GPU renderer',
    () async {
      final before = native.liveRendererCount(), bytes = await fixture();
      final pending = decoder.decode(bytes, options: options);
      bytes.fillRange(0, bytes.length, 0);
      final output = await pending;
      expect(output.buffer.asFloat32List(output.offsetInBytes, 9), [
        -1,
        -1,
        0,
        1,
        -1,
        0,
        0,
        1,
        0,
      ]);
      expect(() => output[0] = 1, throwsUnsupportedError);
      expect(native.liveRendererCount(), before);
    },
  );
  test(
    'native errors cross the isolate and failed calls release admission',
    () async {
      final bytes = await fixture();
      await expectLater(
        decoder.decode(
          Uint8List.sublistView(bytes, 0, bytes.length - 1),
          options: options,
        ),
        throwsA(
          isA<BufferDecodeException>().having(
            (e) => e.code,
            'code',
            BufferDecodeError.invalidData,
          ),
        ),
      );
      await expectLater(
        decoder.decode(bytes, options: options, maxDecodedBytes: 35),
        throwsA(
          isA<BufferDecodeException>().having(
            (e) => e.code,
            'code',
            BufferDecodeError.limitExceeded,
          ),
        ),
      );
      expect(await decoder.decode(bytes, options: options), hasLength(36));
    },
  );
  test('CPU buffer decodes bound concurrency across instances', () async {
    final bytes = await fixture();
    final first = decoder.decode(bytes, options: options);
    final second = const NativeBufferDecoder().decode(bytes, options: options);
    await expectLater(
      decoder.decode(bytes, options: options),
      throwsA(
        isA<BufferDecodeException>().having(
          (e) => e.code,
          'code',
          BufferDecodeError.busy,
        ),
      ),
    );
    expect(await Future.wait([first, second]), hasLength(2));
    expect(await decoder.decode(bytes, options: options), hasLength(36));
  });
}
