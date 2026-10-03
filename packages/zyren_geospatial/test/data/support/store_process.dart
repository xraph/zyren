import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

Future<void> main(List<String> args) async {
  final mode = args[0], directory = Directory(args[1]), label = args[2];
  var held = false;
  final store = FileGeoDataStore(
    directory: directory,
    maxBytes: 1024 * 1024,
    maxEntries: 64,
    onWriteStage: (stage) async {
      if (mode == 'crash' && stage.name == args[3]) exit(71);
      if (mode == 'hold' &&
          !held &&
          stage == GeoStoreWriteStage.payloadStaged) {
        held = true;
        stdout.writeln('ready');
        await stdin.transform(utf8.decoder).first;
      }
    },
  );
  for (var i = 0; i < (mode == 'write' ? 8 : 1); i++) {
    final key = GeoResourceKey(
      sourceId: 'sea',
      sourceVersion: '$label-$i',
      authorizationPartition: 'public',
      address: 'mask/0/0/0',
      representation: 'r8',
      decoderVersion: 1,
    );
    final bytes = Uint8List.fromList([1, 2, 3]);
    if (!await store.write(
      GeoResource(
        key: key,
        bytes: bytes,
        fetchedAt: DateTime.utc(2026),
        checksum: sha256.convert(bytes).toString(),
      ),
    )) {
      exit(72);
    }
  }
  await store.close();
}
