import 'dart:convert';
import 'dart:io';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

class LayerLabSource extends ProceduralTerrainSource {
  bool fail = false;
  LayerLabSource(double west, double east)
    : super(
        scheme: TilingScheme(
          width: 1,
          rectangle: GeographicRectangle(west, -.0003, east, .0003),
        ),
        maximumLevel: 2,
        maximumHeight: 240,
        latency: const Duration(milliseconds: 50),
      );
  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    if (fail) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      context.cancellation.throwIfCancelled();
      throw StateError('Layer lab source failure');
    }
    return super.load(coordinate, context);
  }
}

class LayersFixture {
  static const origin = Vec3(6378137, 0, 0);
  final westSource = LayerLabSource(-.0006, 0),
      eastSource = LayerLabSource(0, .0006);
  late final west = TerrainExtension(id: 'west', source: westSource);
  late final east = TerrainExtension(id: 'east', source: eastSource);
  late final sky = AtmosphereExtension(
    id: 'sky',
    date: DateTime.utc(2026, 3, 20, 12),
  );
  late final overview = GlobeCameraExtension(
    id: 'overview',
    configure: (c) {
      c.camera.position = origin + const Vec3(6500, -4000, 2500);
      c.camera.target = origin;
    },
  );
  late final detail = GlobeCameraExtension(
    id: 'detail',
    configure: (c) {
      c.camera.position = origin + const Vec3(2300, -1700, 1000);
      c.camera.target = origin;
    },
  );
  late final geo = GeospatialPlugin(
    extensions: [west, east, sky, overview, detail],
  );
  late final codec = GeoLayerCodec(geo.layers);
  final scene = Scene()
    ..background = const Color3(.015, .025, .045)
    ..renderSettings = RenderSettings(hdr: true, toneMapping: ToneMapping.aces)
    ..lightDirection = const Vec3(1, -.4, .7)
    ..ambient = .35;
  final camera = PerspectiveCamera(
    position: origin + const Vec3(6500, -4000, 2500),
    target: origin,
    up: const Vec3(0, 0, 1),
    near: 1,
    far: 2e7,
  );
  void failEast() {
    eastSource.fail = true;
    east.terrain.replaceSource(eastSource);
  }

  void retryEast() {
    eastSource.fail = false;
    east.retryFailed();
  }

  Future<bool> restore(File file) async {
    if (!await file.exists()) return false;
    if (await file.length() > codec.maxDocumentBytes) {
      throw const FormatException('Saved layout is too large.');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid saved layout.');
    }
    codec.decode(value);
    return true;
  }

  Future<void> save(File file) async {
    final document = jsonEncode(codec.encode());
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(document, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
