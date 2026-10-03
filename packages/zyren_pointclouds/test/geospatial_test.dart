import 'dart:convert';
import '../../zyren_3d_tiles/test/feature_test.dart' show batchModel;
import '../../zyren_3d_tiles/test/fixtures.dart' show MemoryResolver, tile;
import '../../zyren_3d_tiles/test/streaming_test.dart' show source, settle;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/agents.dart';
import 'package:zyren_pointclouds/geospatial_agents.dart';

class Resolver implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(
        effectiveUri: uri,
        bytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'asset': {'version': '1.1'},
              'geometricError': 0,
              'root': {
                'boundingVolume': {
                  'sphere': [0, 0, 0, 1],
                },
                'geometricError': 0,
                'refine': 'REPLACE',
              },
            }),
          ),
        ),
      );
}

void main() {
  test(
    'resident tile feature properties are verified against actual loaded content',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(refine: 'REPLACE', uri: 'batch')),
        services: AssetServices(
          resolver: MemoryResolver({'/batch': batchModel()}),
        ),
      );
      final camera = PerspectiveCamera(
        position: const Vec3(0, -30, 0),
        up: const Vec3(0, 0, 1),
      );
      final adapter = RealityTilesContext(
        streamer,
        linkForSource: (_) => SourceTileLink(tileId: '0', featureId: 1),
      );
      final before = adapter.revision;
      streamer.update(camera, const ViewportMetrics(100, 100));
      await settle(streamer);
      expect(streamer.failures, isEmpty);
      expect(streamer.visible.keys, ['0']);
      final identity = (Uri.parse('asset:scan'), 'v1', 17);
      final link = adapter.sourceLink(identity)!;
      expect(link['featureIdentityVerified'], isTrue);
      expect(link['featureMetadataVerified'], isTrue);
      expect((link['featureProperties'] as Map)['name'], 'South');
      expect(adapter.revision, greaterThan(before));
      await streamer.dispose();
      expect(adapter.sourceLink(identity)!['featureIdentityVerified'], isFalse);
    },
  );

  test(
    'declared geospatial frame transforms the scene and enriches original sample identity',
    () async {
      final origin = Geodetic.degrees(-87.6, 41.8, 120);
      final reference = RealityGeospatialReference.eastNorthUp(origin);
      final frame = reference.createGroup();
      final ecef = reference.toEcef(Vec3.zero);
      final data = PointCloudData(
        sourceUri: Uri.parse('asset:scan'),
        sourceVersion: 'v1',
        points: [Vec3.zero],
        recordIndices: [17],
      );
      final cloud = ScenePointCloud(data: data);
      frame.add(cloud.object);
      final scene = Scene()..add(frame);
      final up = reference.reference.ellipsoid.surfaceNormal(ecef);
      final camera = PerspectiveCamera(
        position: ecef + up * 5,
        target: ecef,
        up: reference.reference.ellipsoid.eastNorthUpVectors(ecef).north,
      );
      final view = AgentViewportProvider(
        sceneId: 'geo',
        documentId: 'scan',
        instanceId: 'main',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(100, 100),
      );
      final registry = AgentRegistry();
      final provider = RealityContextAgentProvider(
        inner: PointCloudAgentProvider(
          cloud: cloud,
          view: view,
          instanceId: 'survey',
        ),
        geospatial: reference,
      );
      registry.register(provider);
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'pick',
        arguments: {'x': 50, 'y': 50, 'radius': .01},
      );
      expect(result.status, AgentStatus.ok);
      final hit = (result.data['hits'] as List).single as Map;
      expect(hit['recordIndex'], 17);
      expect(hit['sourcePoint'], [0, 0, 0]);
      final geo = hit['geospatial'] as Map;
      expect(geo['longitudeDegrees'], closeTo(-87.6, 1e-9));
      expect(geo['latitudeDegrees'], closeTo(41.8, 1e-9));
      expect(geo['ellipsoidHeightMetres'], closeTo(120, 1e-6));
      expect(hit['tile'], isNull);
      cloud.close();
      registry.dispose();
    },
  );
  test(
    '3D Tiles context reads a live streamer and never infers source membership',
    () async {
      final services = AssetServices(resolver: Resolver());
      final assets = AssetScope(services: services);
      final lease = await assets
          .load(Tiles3D.tileset(Uri.parse('memory:tileset')))
          .result;
      final streamer = Tiles3DStreamer(tileset: lease, services: services);
      streamer.update(PerspectiveCamera(), const ViewportMetrics(100, 100));
      final adapter = RealityTilesContext(streamer);
      final snapshot = adapter.snapshot();
      expect(snapshot['tilesetUri'], 'memory:tileset');
      expect(snapshot['activeRequests'], streamer.stats.activeRequests);
      expect(adapter.sourceLink((Uri.parse('asset:scan'), 'v1', 17)), isNull);
      expect(snapshot['physicalGpuResidentBytes'], isNull);
      await streamer.dispose();
      await assets.close();
    },
  );
}
