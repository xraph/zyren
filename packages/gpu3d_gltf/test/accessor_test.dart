import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/src/accessor.dart';
import 'package:gpu3d_gltf/src/checked.dart';
import 'package:test/test.dart';

AccessorReader reader(
  List<Map<String, Object?>> accessors,
  List<Map<String, Object?>> views,
  Uint8List bytes, {
  int budget = 1024,
}) => AccessorReader(
  {
    'accessors': accessors,
    'bufferViews': views,
    'buffers': [
      {'byteLength': bytes.length},
    ],
  },
  [bytes],
  budget: DecodeBudget(budget),
);
TypeMatcher<AssetLoadException> invalid([
  AssetLoadError code = AssetLoadError.invalidData,
]) => isA<AssetLoadException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'padded matrix layouts support multiple elements and short final columns',
    () {
      for (final (shape, rows, size, componentType) in [
        ('MAT2', 2, 1, 5121),
        ('MAT3', 3, 1, 5121),
        ('MAT3', 3, 2, 5123),
      ]) {
        final column = (rows * size + 3) & ~3, components = rows * rows;
        final stride = column * rows, span = column * (rows - 1) + rows * size;
        final bytes = Uint8List(stride + span)
          ..fillRange(0, stride + span, 255);
        final data = ByteData.sublistView(bytes);
        for (var element = 0; element < 2; element++) {
          for (var col = 0; col < rows; col++) {
            for (var row = 0; row < rows; row++) {
              final at = element * stride + col * column + row * size;
              final value = element * components + col * rows + row + 1;
              if (size == 1) {
                data.setUint8(at, value);
              } else {
                data.setUint16(at, value, Endian.little);
              }
            }
          }
        }
        expect(
          reader(
            [
              {
                'bufferView': 0,
                'componentType': componentType,
                'type': shape,
                'count': 2,
              },
            ],
            [
              {'buffer': 0, 'byteLength': bytes.length},
            ],
            bytes,
          ).read(0).values,
          List.generate(components * 2, (i) => i + 1),
        );
      }
    },
  );
  test(
    'optional fields reject explicit null and indices reject restart sentinels',
    () {
      final base = <String, Object?>{
        'bufferView': 0,
        'componentType': 5121,
        'type': 'SCALAR',
        'count': 1,
      };
      final views = [
            {'buffer': 0, 'byteLength': 4},
          ],
          bytes = Uint8List.fromList([255, 0, 0, 0]);
      for (final key in ['byteOffset', 'normalized', 'sparse', 'min', 'max']) {
        expect(
          () => reader(
            [
              {...base, key: null},
            ],
            views,
            bytes,
          ).read(0),
          throwsA(invalid()),
        );
      }
      final r = reader([base], views, bytes);
      expect(r.read(0).values, [255]);
      expect(() => r.read(0, usage: AccessorUsage.indices), throwsA(invalid()));
    },
  );
  test('sharing an attribute view requires an explicit stride', () {
    final r = reader(
      [
        {'bufferView': 0, 'componentType': 5126, 'type': 'VEC3', 'count': 1},
        {
          'bufferView': 0,
          'componentType': 5126,
          'type': 'VEC3',
          'count': 1,
          'byteOffset': 12,
        },
      ],
      [
        {'buffer': 0, 'byteLength': 24},
      ],
      Uint8List(24),
    );
    r.read(0, usage: AccessorUsage.vertex);
    expect(() => r.read(1, usage: AccessorUsage.vertex), throwsA(invalid()));
  });
  test(
    'interleaved attributes use offsets and retain exact unsigned indices',
    () {
      final bytes = Uint8List(32);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < 8; i++) {
        data.setFloat32(i * 4, i.toDouble(), Endian.little);
      }
      final r = reader(
        [
          {
            'bufferView': 0,
            'componentType': 5126,
            'type': 'VEC3',
            'count': 2,
            'byteOffset': 4,
          },
        ],
        [
          {'buffer': 0, 'byteLength': 32, 'byteStride': 16},
        ],
        bytes,
      );
      expect(r.read(0, usage: AccessorUsage.vertex).values, [1, 2, 3, 5, 6, 7]);
      expect(r.read(0), same(r.read(0)));
      final uints = Uint8List(4)
        ..buffer.asByteData().setUint32(0, 0xfffffffe, Endian.little);
      expect(
        reader(
          [
            {
              'bufferView': 0,
              'componentType': 5125,
              'type': 'SCALAR',
              'count': 1,
            },
          ],
          [
            {'buffer': 0, 'byteLength': 4},
          ],
          uints,
        ).read(0).values,
        [0xfffffffe],
      );
    },
  );
  test(
    'signed normalization clamps the minimum and unsigned normalization reaches one',
    () {
      for (final (type, bytes, expected) in [
        (5120, Uint8List.fromList([128, 127]), [-1.0, 1.0]),
        (5121, Uint8List.fromList([0, 255]), [0.0, 1.0]),
        (5122, Uint8List.fromList([0, 128, 255, 127]), [-1.0, 1.0]),
        (5123, Uint8List.fromList([0, 0, 255, 255]), [0.0, 1.0]),
      ]) {
        expect(
          reader(
            [
              {
                'bufferView': 0,
                'componentType': type,
                'type': 'SCALAR',
                'count': 2,
                'normalized': true,
              },
            ],
            [
              {'buffer': 0, 'byteLength': bytes.length},
            ],
            bytes,
          ).read(0).values,
          expected,
        );
      }
    },
  );
  test('matrix columns respect padding and omitted final padding', () {
    final bytes = Uint8List.fromList([1, 2, 3, 99, 4, 5, 6, 99, 7, 8, 9]);
    final r = reader(
      [
        {'bufferView': 0, 'componentType': 5121, 'type': 'MAT3', 'count': 1},
      ],
      [
        {'buffer': 0, 'byteLength': 11},
      ],
      bytes,
    );
    expect(r.read(0).values, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });
  test(
    'sparse values replace a zero-filled base with strict increasing indices',
    () {
      final bytes = Uint8List.fromList([0, 2, 0, 0, 7, 9]);
      final accessor = <String, Object?>{
        'componentType': 5121,
        'type': 'SCALAR',
        'count': 3,
        'sparse': {
          'count': 2,
          'indices': {'bufferView': 0, 'componentType': 5121},
          'values': {'bufferView': 1},
        },
      };
      final views = [
        {'buffer': 0, 'byteLength': 2},
        {'buffer': 0, 'byteOffset': 4, 'byteLength': 2},
      ];
      expect(reader([accessor], views, bytes).read(0).values, [7, 0, 9]);
      for (final indices in [
        [0, 0],
        [2, 0],
        [0, 3],
      ]) {
        final bad = Uint8List.fromList(bytes)..setRange(0, 2, indices);
        expect(
          () => reader([accessor], views, bad).read(0),
          throwsA(invalid()),
        );
      }
    },
  );
  test(
    'bounds, alignment, invalid flags and budgets fail before publication',
    () {
      final base = <String, Object?>{
        'bufferView': 0,
        'componentType': 5126,
        'type': 'VEC3',
        'count': 1,
      };
      final bytes = Uint8List(16);
      for (final change in [
        {'count': 2},
        {'byteOffset': 2},
        {'normalized': true},
        {'componentType': 5124},
        {'count': -1},
      ]) {
        expect(
          () => reader(
            [
              {...base, ...change},
            ],
            [
              {'buffer': 0, 'byteLength': 16},
            ],
            bytes,
          ).read(0),
          throwsA(invalid()),
        );
      }
      expect(
        () => reader(
          [base],
          [
            {'buffer': 0, 'byteLength': 16},
          ],
          bytes,
          budget: 8,
        ).read(0),
        throwsA(invalid(AssetLoadError.limitExceeded)),
      );
      ByteData.sublistView(bytes).setFloat32(0, double.nan, Endian.little);
      expect(
        () => reader(
          [base],
          [
            {'buffer': 0, 'byteLength': 16},
          ],
          bytes,
        ).read(0),
        throwsA(invalid()),
      );
    },
  );
  test('indices cannot alias vertex attributes or carry a vertex stride', () {
    final r = reader(
      [
        {'bufferView': 0, 'componentType': 5123, 'type': 'SCALAR', 'count': 1},
      ],
      [
        {'buffer': 0, 'byteLength': 4},
      ],
      Uint8List(4),
    );
    r.read(0, usage: AccessorUsage.vertex);
    expect(() => r.read(0, usage: AccessorUsage.indices), throwsA(invalid()));
  });
}
