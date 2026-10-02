import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'atmosphere_table_fixture.dart';

void main() {
  test(
    'binary and scanline EXR preserve half values and stacked volume order',
    () {
      final rgba = halfTable(8, 34);
      final decoder = AtmosphereTableDecoder();
      final binary = decoder.decode(
        rgba,
        format: AtmosphereLutFormat.binary,
        width: 8,
        height: 17,
        depth: 2,
      );
      expect(binary.bytes, rgba);
      expect(binary.value(0, 0, 0, 3), 1);
      expect(() => binary.bytes[0] = 0, throwsUnsupportedError);
      for (final compression in [0, 2, 3]) {
        final exr = decoder.decode(
          tableExr(8, 34, rgba, compression: compression),
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 17,
          depth: 2,
        );
        expect(exr.bytes, binary.bytes, reason: 'compression $compression');
      }
      rgba[0] = 1;
      expect(binary.bytes[0], 0);
    },
  );
  test(
    'truncation, nonfinite halves and encoded/decoded limits are checked',
    () {
      final decoder = AtmosphereTableDecoder();
      final rgba = halfTable(2, 2), exr = tableExr(2, 2, halfTable(2, 2));
      for (var n = 0; n < exr.length; n++) {
        expect(
          () => decoder.decode(
            Uint8List.sublistView(exr, 0, n),
            format: AtmosphereLutFormat.exr,
            width: 2,
            height: 2,
          ),
          throwsA(isA<AssetLoadException>()),
          reason: 'length $n',
        );
      }
      for (final word in [0x7c00, 0xfc00, 0x7e00]) {
        final bad = Uint8List.fromList(rgba);
        ByteData.sublistView(bad).setUint16(0, word, Endian.little);
        for (final format in AtmosphereLutFormat.values) {
          expect(
            () => decoder.decode(
              format == AtmosphereLutFormat.binary ? bad : tableExr(2, 2, bad),
              format: format,
              width: 2,
              height: 2,
            ),
            throwsA(isA<AssetLoadException>()),
          );
        }
      }
      expect(
        () => AtmosphereTableDecoder(
          maxEncodedBytes: 8,
        ).decode(rgba, format: AtmosphereLutFormat.binary, width: 2, height: 2),
        throwsA(isA<AssetLoadException>()),
      );
      expect(
        () => AtmosphereTableDecoder(
          maxDecodedBytes: 8,
        ).decode(rgba, format: AtmosphereLutFormat.binary, width: 2, height: 2),
        throwsA(isA<AssetLoadException>()),
      );
      expect(
        () => decoder.decode(
          rgba,
          format: AtmosphereLutFormat.binary,
          width: 1 << 30,
          height: 2,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'invalid EXR layout, duplicate offsets and dimensions cannot publish a table',
    () {
      final decoder = AtmosphereTableDecoder();
      final valid = tableExr(8, 32, halfTable(8, 32));
      final tiled = Uint8List.fromList(valid)..[5] = 2;
      expect(
        () => decoder.decode(
          tiled,
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 32,
        ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.unsupportedFeature,
          ),
        ),
      );
      expect(
        () => decoder.decode(
          valid,
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 31,
        ),
        throwsA(isA<AssetLoadException>()),
      );
      // Locate the header terminator using independent attribute lengths.
      var at = 8;
      while (valid[at] != 0) {
        while (valid[at++] != 0) {}
        while (valid[at++] != 0) {}
        final n = ByteData.sublistView(valid).getUint32(at, Endian.little);
        at += n + 4;
      }
      final bad = Uint8List.fromList(valid);
      bad.setRange(at + 9, at + 17, bad, at + 1);
      expect(
        () => decoder.decode(
          bad,
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 32,
        ),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );
  final sourcePath = Platform.environment['ZYREN_SOURCE_LUTS'];
  test(
    'EXR expansion, duplicate attributes and channel sampling are bounded',
    () {
      final decoder = AtmosphereTableDecoder();
      final valid = tableExr(8, 16, halfTable(8, 16));
      int headerEnd(Uint8List bytes) {
        var at = 8;
        while (bytes[at] != 0) {
          while (bytes[at++] != 0) {}
          while (bytes[at++] != 0) {}
          at += 4 + ByteData.sublistView(bytes).getUint32(at, Endian.little);
        }
        return at;
      }

      void rejects(Uint8List bytes, AssetLoadError code) => expect(
        () => decoder.decode(
          bytes,
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 16,
        ),
        throwsA(isA<AssetLoadException>().having((e) => e.code, 'code', code)),
      );
      final end = headerEnd(valid);
      final offset = ByteData.sublistView(
        valid,
      ).getUint64(end + 1, Endian.little);
      final zipped = ZLibEncoder().convert(Uint8List(100000));
      final bomb = Uint8List.fromList([...valid.take(offset + 8), ...zipped]);
      ByteData.sublistView(
        bomb,
      ).setUint32(offset + 4, zipped.length, Endian.little);
      rejects(bomb, AssetLoadError.limitExceeded);
      // The first attribute ends before the compression attribute.
      final channelLength = ByteData.sublistView(
        valid,
      ).getUint32(24, Endian.little);
      final duplicate = Uint8List.fromList([
        ...valid.take(end),
        ...valid.sublist(8, 28 + channelLength),
        ...valid.skip(end),
      ]);
      rejects(duplicate, AssetLoadError.invalidData);
      final subsampled = Uint8List.fromList(valid);
      ByteData.sublistView(subsampled).setUint32(38, 2, Endian.little);
      rejects(subsampled, AssetLoadError.unsupportedFeature);
      final cancelled = _Cancelled();
      expect(
        () => decoder.decode(
          valid,
          format: AtmosphereLutFormat.exr,
          width: 8,
          height: 16,
          cancellation: cancelled,
        ),
        throwsA(isA<LoadCancelled>()),
      );
    },
  );
  test(
    'pinned binary and EXR source assets agree within half quantization',
    () {
      final decoder = AtmosphereTableDecoder();
      for (final (name, width, height, depth) in [
        ('transmittance', 256, 64, 1),
        ('irradiance', 64, 16, 1),
        ('scattering', 256, 128, 32),
        ('single_mie_scattering', 256, 128, 32),
        ('higher_order_scattering', 256, 128, 32),
      ]) {
        final binary = decoder.decode(
          File('$sourcePath/$name.bin').readAsBytesSync(),
          format: AtmosphereLutFormat.binary,
          width: width,
          height: height,
          depth: depth,
        );
        final exr = decoder.decode(
          File('$sourcePath/$name.exr').readAsBytesSync(),
          format: AtmosphereLutFormat.exr,
          width: width,
          height: height,
          depth: depth,
        );
        final a = ByteData.sublistView(binary.bytes),
            b = ByteData.sublistView(exr.bytes);
        var maxUnits = 0;
        for (var i = 0; i < binary.bytes.length; i += 2) {
          final error =
              (a.getUint16(i, Endian.little) - b.getUint16(i, Endian.little))
                  .abs();
          if (error > maxUnits) maxUnits = error;
        }
        expect(maxUnits, lessThanOrEqualTo(1), reason: name);
        print(
          'Source LUT $name: ${binary.bytes.length} decoded bytes, max half-bit distance $maxUnits.',
        );
      }
    },
    skip: sourcePath == null
        ? 'Set ZYREN_SOURCE_LUTS to hash-verified pinned assets.'
        : false,
  );
}

final class _Cancelled implements LoadCancellation {
  @override
  bool get isCancelled => true;
  @override
  void throwIfCancelled() => throw LoadCancelled();
  @override
  Registration onCancel(void Function() callback) {
    callback();
    return Registration(() {});
  }
}
