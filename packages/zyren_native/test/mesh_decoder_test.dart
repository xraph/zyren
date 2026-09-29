import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/src/bindings.dart' as native;
import 'package:zyren_native/src/mesh_packet.dart';

Future<Uint8List> fixture(String kind) =>
    File('../../test_assets/compression/quad-$kind.drc').readAsBytes();
Matcher error(BufferDecodeError code) =>
    isA<BufferDecodeException>().having((e) => e.code, 'code', code);

void main() {
  const decoder = NativeMeshDecoder();
  test(
    'Draco CPU worker preserves attributes, topology and input ownership',
    () async {
      final before = native.liveRendererCount();
      for (final kind in ['sequential', 'edgebreaker']) {
        final bytes = await fixture(kind);
        final pending = decoder.decode(bytes, encoding: MeshEncoding.draco);
        bytes.fillRange(0, bytes.length, 0);
        final mesh = await pending;
        expect(mesh.vertexCount, 4);
        expect(mesh.indices, hasLength(6));
        expect(mesh.attributes.map((a) => a.id).toSet(), {8, 21, 77});
        final positions = mesh.attributes.singleWhere((a) => a.id == 77).bytes;
        final values = ByteData.sublistView(positions);
        final corners = {
          for (var i = 0; i < 4; i++)
            (
              values.getFloat32(i * 12, Endian.little).round(),
              values.getFloat32(i * 12 + 4, Endian.little).round(),
              values.getFloat32(i * 12 + 8, Endian.little).round(),
            ),
        };
        expect(corners, {(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)});
        expect(() => positions[0] = 1, throwsUnsupportedError);
        expect(() => mesh.indices[0] = 1, throwsUnsupportedError);
      }
      expect(native.liveRendererCount(), before);
    },
  );
  test(
    'Draco limits and corruption cross the isolate without blocking later work',
    () async {
      final bytes = await fixture('edgebreaker');
      await expectLater(
        decoder.decode(
          bytes,
          encoding: MeshEncoding.draco,
          limits: const MeshDecodeLimits(maxVertices: 3),
        ),
        throwsA(error(BufferDecodeError.limitExceeded)),
      );
      await expectLater(
        decoder.decode(
          Uint8List.sublistView(bytes, 0, bytes.length - 2),
          encoding: MeshEncoding.draco,
        ),
        throwsA(error(BufferDecodeError.invalidData)),
      );
      final first = decoder.decode(bytes, encoding: MeshEncoding.draco);
      final second = decoder.decode(bytes, encoding: MeshEncoding.draco);
      await expectLater(
        decoder.decode(bytes, encoding: MeshEncoding.draco),
        throwsA(error(BufferDecodeError.busy)),
      );
      expect(await Future.wait([first, second]), hasLength(2));
    },
  );
  test(
    'mesh packet rejects incomplete headers, huge counts and invalid layouts',
    () {
      for (final packet in [
        Uint8List(0),
        Uint8List(12),
        Uint8List.fromList(List.filled(40, 255)),
      ]) {
        expect(
          () => decodeMeshPacket(packet, const MeshDecodeLimits()),
          throwsA(error(BufferDecodeError.invalidData)),
        );
      }
    },
  );
}
