import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../../terrain/quantized_mesh_fixture.dart' show gridMeshFixture;

GeoResourceKey offlineKey(String path) => GeoResourceKey(
  sourceId: path.startsWith('imagery/') ? 'imagery' : 'terrain',
  sourceVersion: '1',
  authorizationPartition: 'public',
  address: path,
  representation: path.endsWith('.png')
      ? 'png'
      : path.endsWith('.json')
      ? 'json'
      : 'quantized-mesh',
  decoderVersion: 1,
  projection: 'EPSG:4326',
);
GeoSourceMetadata offlinePermission(GeoResourceKey key) => GeoSourceMetadata(
  sourceId: key.sourceId,
  sourceVersion: key.sourceVersion,
  mayPersist: true,
  mayExportOffline: true,
  credits: ['Synthetic offline fixture'],
);
Future<Map<GeoResourceKey, Uint8List>> offlinePayloads() async {
  var root = Directory.current;
  while (!File('${root.path}/test_assets/images/corners.png').existsSync()) {
    if (root.parent.path == root.path) {
      throw StateError('Fixture root unavailable.');
    }
    root = root.parent;
  }
  return {
    offlineKey('terrain/layer.json'): Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'quantized-mesh-1.0',
          'version': '1',
          'maxzoom': 1,
          'tiles': ['{z}/{x}/{y}.terrain'],
          'attribution': 'Synthetic terrain fixture',
        }),
      ),
    ),
    offlineKey('terrain/0/0/0.terrain'): gridMeshFixture(),
    offlineKey('imagery/0/0/0.png'): await File(
      '${root.path}/test_assets/images/corners.png',
    ).readAsBytes(),
  };
}

GeoResource offlineResource(GeoResourceKey key, Uint8List bytes) => GeoResource(
  key: key,
  bytes: bytes,
  fetchedAt: DateTime.now().toUtc(),
  checksum: sha256.convert(bytes).toString(),
);
GeoTerrainResourceResolver offlineAdapter(
  GeoResourceResolver resolver, {
  GeoReadPolicy? policy,
}) => GeoTerrainResourceResolver(
  resources: resolver,
  policy: policy ?? GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
  baseUri: Uri.parse('geo-resource://fixture/'),
  keyForUri: (uri) => offlineKey(uri.path.substring(1)),
  authorizationPartition: 'public',
  sourceVersions: {'terrain': '1', 'imagery': '1'},
);
Future<QuantizedMeshTerrainSource> offlineTerrain(
  GeoResourceResolver resolver,
) => QuantizedMeshTerrainSource.open(
  uri: Uri.parse('geo-resource://fixture/terrain/layer.json'),
  datasetId: 'offline-fixture',
  resolver: offlineAdapter(resolver),
  cancellation: LoadCancellationSource(),
);
TileLoadContext offlineContext(
  TerrainSource source,
  TileCoordinate coordinate,
) => TileLoadContext(
  sourceIdentity: source.identity,
  cancellation: LoadCancellationSource(),
  byteBudget: source.describe(coordinate).decodedBytes,
);

Future<void> main(List<String> args) async {
  final store = FileGeoDataStore(
    directory: Directory(args.single),
    maxBytes: 1024 * 1024,
    maxEntries: 32,
  );
  final resolver = GeoResourceResolver(
    store: store,
    metadata: offlinePermission,
    fetch: (_, _) async =>
        throw StateError('Cold offline process attempted transport'),
  );
  final source = await offlineTerrain(resolver);
  final inside = await source.load(
    const TileCoordinate(0, 0, 0),
    offlineContext(source, const TileCoordinate(0, 0, 0)),
  );
  if (inside.geometry.positions.isEmpty ||
      !inside.attributions.contains('Synthetic terrain fixture')) {
    exit(80);
  }
  for (final tile in [
    const TileCoordinate(1, 0, 0),
    const TileCoordinate(0, 0, 1),
  ]) {
    try {
      await source.load(tile, offlineContext(source, tile));
      exit(81);
    } on GeoDataException catch (e) {
      if (e.code != GeoDataError.offlineMiss) rethrow;
    }
  }
  final image = await resolver.read(
    offlineKey('imagery/0/0/0.png'),
    GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
    cancellation: LoadCancellationSource(),
  );
  if (image.bytes.length < 8 || image.bytes[0] != 137 || image.bytes[1] != 80) {
    exit(82);
  }
  await resolver.close();
  await store.close();
  stdout.writeln('cold-offline-ok');
}
