import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_gltf/src/document.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

final basic = <String, Object?>{
  'asset': {'version': '2.0'},
};
TypeMatcher<AssetLoadException> invalid([
  AssetLoadError code = AssetLoadError.invalidData,
]) => isA<AssetLoadException>().having((e) => e.code, 'code', code);
GltfDocument parse(List<int> bytes, {GltfLimits limits = const GltfLimits()}) =>
    GltfDocument.parse(Uint8List.fromList(bytes), limits: limits);

void main() {
  test('seeded GLB mutations produce a document or a typed failure', () {
    final source = glb(basic, binary: [1, 2, 3, 4]);
    final random = Random(319);
    for (var iteration = 0; iteration < 400; iteration++) {
      final bytes = Uint8List.fromList(source);
      bytes[random.nextInt(bytes.length)] ^= 1 << random.nextInt(8);
      try {
        parse(bytes);
      } catch (error) {
        expect(error, isA<AssetLoadException>());
      }
    }
  });
  test(
    'GLB extracts JSON and binary while ignoring unknown trailing chunks',
    () {
      final document = parse(glb(basic, binary: [1, 2, 3], unknown: [9]));
      expect(document.root['asset'], {'version': '2.0'});
      expect(document.binary, [1, 2, 3, 0]);
      expect(parse(utf8.encode(jsonEncode(basic))).binary, isNull);
    },
  );
  test('every GLB truncation fails with a typed diagnostic', () {
    final bytes = glb(basic, binary: [1, 2, 3, 4]);
    for (var length = 0; length < bytes.length; length++) {
      expect(
        () => parse(bytes.sublist(0, length)),
        throwsA(invalid()),
        reason: '$length bytes',
      );
    }
  });
  test(
    'container version, length, chunk alignment and known order are checked',
    () {
      final good = glb(basic, binary: [1, 2, 3, 4]);
      for (final (offset, value) in [
        (4, 1),
        (8, good.length + 4),
        (12, 3),
        (16, 0x004e4942),
        (good.length - 8, 0x4e4f534a),
      ]) {
        final bytes = Uint8List.fromList(good);
        ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);
        expect(() => parse(bytes), throwsA(isA<AssetLoadException>()));
      }
    },
  );
  test('JSON limits apply before parsing and duplicate names are rejected', () {
    expect(
      () => parse(
        utf8.encode(jsonEncode(basic)),
        limits: const GltfLimits(maxJsonBytes: 4),
      ),
      throwsA(invalid(AssetLoadError.limitExceeded)),
    );
    expect(
      () => parse(
        utf8.encode('{"asset":{"version":"2.0"},"extras":[[[[0]]]]}'),
        limits: const GltfLimits(maxJsonDepth: 4),
      ),
      throwsA(invalid(AssetLoadError.limitExceeded)),
    );
    for (final json in [
      '{"asset":{"version":"2.0","version":"1.0"}}',
      '{"asset":{"version":"2.0"},"asset":{"version":"2.0"}}',
      '{"asset":{"version":"2.0"},"extras":{"a":0,"\\u0061":1}}',
    ]) {
      expect(() => parse(utf8.encode(json)), throwsA(invalid()));
    }
  });
  test(
    'version and required extensions fail before resolving dependencies',
    () {
      for (final asset in [
        {'version': '1.0'},
        {'version': '2.0', 'minVersion': '2.1'},
      ]) {
        expect(
          () => parse(utf8.encode(jsonEncode({'asset': asset}))),
          throwsA(invalid(AssetLoadError.unsupportedFeature)),
        );
      }
      final doc = {
        ...basic,
        'extensionsUsed': ['VENDOR_optional'],
      };
      expect(
        parse(utf8.encode(jsonEncode(doc))).issues.single.code,
        'gltf.unsupportedOptionalExtension',
      );
      doc['extensionsRequired'] = ['VENDOR_optional'];
      expect(
        () => parse(utf8.encode(jsonEncode(doc))),
        throwsA(
          invalid(
            AssetLoadError.unsupportedFeature,
          ).having((e) => e.fieldPath, 'path', 'extensionsRequired[0]'),
        ),
      );
    },
  );
}
