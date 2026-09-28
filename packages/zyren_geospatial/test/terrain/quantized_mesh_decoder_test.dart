import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'quantized_mesh_fixture.dart';

void main() {
  const rectangle = GeographicRectangle(-.0001, -.0001, .0001, .0001);
  final decoder = QuantizedMeshDecoder();
  TerrainTile decode(Uint8List bytes, {double skirtDepth = 50}) =>
      decoder.decode(
        bytes,
        rectangle: rectangle,
        skirtDepth: skirtDepth,
        cancellation: TestCancellation(),
      );
  final invalid = throwsA(
    isA<AssetLoadException>().having(
      (e) => e.code,
      'code',
      AssetLoadError.invalidData,
    ),
  );

  test(
    'decodes zigzag and high-water indices into local ECEF and north-up UVs',
    () {
      final tile = decode(meshFixture());
      expect(tile.geometry.indices.take(6), [0, 1, 2, 2, 1, 3]);
      expect(tile.geometry.uv0!.take(8), [0, 1, 1, 1, 0, 0, 1, 0]);
      expect(tile.geometry.positions.every((v) => v.abs() < 1000), isTrue);
      final first = tile.origin + readVec(tile.geometry.positions);
      final expected = Ellipsoid.wgs84.toEcef(Geodetic(-.0001, -.0001, 100));
      expect((first - expected).length, lessThan(.0001));
      expect(tile.geometry.positions.length, 12 * 3);
      final skirt = tile.origin + readVec(tile.geometry.positions, 12);
      expect((first - skirt).length, closeTo(50, .001));
      expect(tile.imagery.levels.single.length, 4);
    },
  );

  test('surface normals follow slope and skirts face outward', () {
    final tile = decode(meshFixture());
    final p = tile.geometry.positions, n = tile.geometry.normals;
    for (var i = 0; i < n.length; i += 3) {
      expect(readVec(n, i).length, closeTo(1, 1e-6));
    }
    for (var i = 0; i < 6; i += 3) {
      final ids = tile.geometry.indices.skip(i).take(3).toList();
      final normal = (readVec(p, ids[1] * 3) - readVec(p, ids[0] * 3)).cross(
        readVec(p, ids[2] * 3) - readVec(p, ids[0] * 3),
      );
      expect(normal.dot(readVec(n, ids[0] * 3)), greaterThan(0));
    }
  });

  test('uses oct normals and rejects incorrect extension lengths', () {
    final bytes = meshFixture(normals: true);
    expect(decode(bytes).geometry.normals.first, closeTo(1, .0001));
    bytes[bytes.length - 12] = 7;
    expect(() => decode(bytes), invalid);
  });

  test('checks every truncation and unknown extension length', () {
    final bytes = meshFixture();
    for (var end = 0; end < bytes.length; end++) {
      expect(
        () => decode(Uint8List.sublistView(bytes, 0, end)),
        invalid,
        reason: 'length=$end',
      );
    }
    expect(
      decode(
        Uint8List.fromList([...bytes, 99, 2, 0, 0, 0, 5, 6]),
      ).geometry.indices.length,
      30,
    );
    expect(
      () => decode(Uint8List.fromList([...bytes, 99, 255, 255, 255, 255])),
      invalid,
    );
  });

  test(
    'rejects invalid headers, deltas, high-water codes and edge membership',
    () {
      for (final corrupt in <void Function(ByteData)>[
        (b) => b.setFloat64(0, double.nan, Endian.little),
        (b) => b.setFloat32(24, 300, Endian.little),
        (b) => b.setUint16(92, 1, Endian.little),
        (b) => b.setUint16(120, 1, Endian.little),
        (b) => b.setUint16(136, 1, Endian.little),
      ]) {
        final bytes = meshFixture();
        corrupt(ByteData.sublistView(bytes));
        expect(() => decode(bytes), invalid);
      }
    },
  );

  test('counts and cancellation fail before allocation', () {
    final bytes = meshFixture();
    ByteData.sublistView(bytes).setUint32(88, 0xffffffff, Endian.little);
    expect(
      () => decode(bytes),
      throwsA(
        isA<AssetLoadException>().having(
          (e) => e.code,
          'code',
          AssetLoadError.limitExceeded,
        ),
      ),
    );
    final cancel = TestCancellation()..cancel();
    expect(
      () => decoder.decode(
        meshFixture(),
        rectangle: rectangle,
        cancellation: cancel,
      ),
      throwsA(isA<LoadCancelled>()),
    );
  });

  test(
    'supports 65,536 vertices with uint16 and 65,537 with aligned uint32',
    () {
      final large = QuantizedMeshDecoder(
        limits: QuantizedMeshLimits(
          maxVertices: 70000,
          maxEncodedBytes: 1000000,
        ),
      );
      for (final count in [65536, 65537]) {
        final tile = large.decode(
          meshFixture(vertexCount: count),
          rectangle: rectangle,
          cancellation: TestCancellation(),
        );
        expect(tile.geometry.indices.take(6), [0, 1, 2, 2, 1, 3]);
        expect(tile.geometry.positions.length, (count + 8) * 3);
      }
    },
  );
}

Vec3 readVec(List<double> values, [int offset = 0]) =>
    Vec3(values[offset], values[offset + 1], values[offset + 2]);
