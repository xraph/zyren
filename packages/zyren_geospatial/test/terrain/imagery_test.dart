import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'quantized_mesh_fixture.dart' show TestCancellation;

class ImageryResolver implements ByteSourceResolver {
  final paths = <String>[];
  Completer<void>? gate;
  Object? error;
  int byteLength = 1;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    paths.add(uri.path);
    await gate?.future;
    if (error case final failure?) throw failure;
    return ResolvedSource(effectiveUri: uri, bytes: Uint8List(byteLength));
  }
}

class ImageryDecoder implements ImageDecoder {
  Completer<void>? gate;
  bool started = false;
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    started = true;
    await gate?.future;
    return ImageData(
      size: PhysicalSize(2, 2),
      pixels: Uint8List.fromList([
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
      ]),
    );
  }
}

class SolidImagery extends RasterImagerySource {
  final List<int> color;
  @override
  final String identity;
  SolidImagery(this.identity, this.color);
  @override
  String get attribution => identity;
  @override
  ImageryProjection get projection => ImageryProjection.geographic;
  @override
  int get maximumLevel => 0;
  @override
  int get tileSize => 2;
  @override
  int get maxEncodedBytes => 1;
  @override
  Future<ImageData> load(
    TileCoordinate coordinate,
    LoadCancellation cancellation,
  ) async => ImageData(
    size: PhysicalSize(2, 2),
    pixels: Uint8List.fromList([for (var i = 0; i < 4; i++) ...color]),
  );
}

void main() {
  test(
    'layer blending uses linear light with alpha and visible credits',
    () async {
      final source = ImageryTerrainSource(
        terrain: ProceduralTerrainSource(),
        outputSize: 2,
        layers: [
          ImageryLayer(SolidImagery('Red', [255, 0, 0, 255])),
          ImageryLayer(SolidImagery('Blue', [0, 0, 255, 128])),
          ImageryLayer(SolidImagery('Hidden', [0, 255, 0, 255]), opacity: 0),
        ],
      );
      const coordinate = TileCoordinate(0, 0, 0);
      final loaded = await source.load(
        coordinate,
        TileLoadContext(
          sourceIdentity: source.identity,
          cancellation: TestCancellation(),
          byteBudget: source.describe(coordinate).decodedBytes,
        ),
      );
      expect(loaded.imagery.levels.single.take(4), [187, 0, 188, 255]);
      expect(loaded.attributions, ['Blue', 'Red']);
    },
  );
  test(
    'bounded imagery reads, dimensions and failures keep secrets out of errors',
    () async {
      for (final (resolver, size, limit, code) in [
        (ImageryResolver()..byteLength = 2, 2, 1, AssetLoadError.limitExceeded),
        (ImageryResolver(), 4, 10, AssetLoadError.invalidData),
        (
          ImageryResolver()..error = StateError('private-query-token'),
          2,
          10,
          AssetLoadError.sourceFailed,
        ),
      ]) {
        final source = TemplateImagerySource(
          baseUri: Uri.parse('https://imagery.test/'),
          template: '{z}/{x}/{y}.png?key=private-query-token',
          datasetId: 'fixture',
          tileSize: size,
          maxEncodedBytes: limit,
          services: AssetServices(
            resolver: resolver,
            imageDecoder: ImageryDecoder(),
          ),
        );
        await expectLater(
          source.load(const TileCoordinate(0, 0, 0), TestCancellation()),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => e.toString(),
                  'message',
                  isNot(contains('private-query-token')),
                )
                .having((e) => e.issue.sourceUri, 'source', isNull),
          ),
        );
      }
    },
  );
  test('cancelled imagery retains its CPU decoder admission', () async {
    final decoder = ImageryDecoder()..gate = Completer<void>();
    final source = TemplateImagerySource(
      baseUri: Uri.parse('https://imagery.test/'),
      template: '{z}/{x}/{y}.png',
      datasetId: 'fixture',
      tileSize: 2,
      services: AssetServices(
        resolver: ImageryResolver(),
        imageDecoder: decoder,
      ),
    );
    final cancel = TestCancellation();
    var finished = false;
    final future = source
        .load(const TileCoordinate(0, 0, 0), cancel)
        .whenComplete(() => finished = true);
    final rejected = expectLater(future, throwsA(isA<LoadCancelled>()));
    while (!decoder.started) {
      await Future<void>.delayed(Duration.zero);
    }
    cancel.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      expect(finished, isFalse);
    } finally {
      decoder.gate!.complete();
      await rejected;
    }
  });
  test(
    'cancelled imagery retains its physical read until it settles',
    () async {
      final resolver = ImageryResolver()..gate = Completer<void>();
      final source = TemplateImagerySource(
        baseUri: Uri.parse('https://imagery.test/'),
        template: '{z}/{x}/{y}.png',
        datasetId: 'fixture',
        tileSize: 2,
        services: AssetServices(
          resolver: resolver,
          imageDecoder: ImageryDecoder(),
        ),
      );
      final cancel = TestCancellation();
      var finished = false;
      final future = source
          .load(const TileCoordinate(0, 0, 0), cancel)
          .whenComplete(() => finished = true);
      final rejected = expectLater(future, throwsA(isA<LoadCancelled>()));
      while (resolver.paths.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      cancel.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      try {
        expect(finished, isFalse);
      } finally {
        resolver.gate!.complete();
        await rejected;
      }
    },
  );
  test('geographic XYZ and TMS URLs preserve south-origin coordinates', () {
    final services = AssetServices(
      resolver: ImageryResolver(),
      imageDecoder: ImageryDecoder(),
    );
    final xyz = TemplateImagerySource(
      baseUri: Uri.parse('https://imagery.test/'),
      template: '{z}/{x}/{y}.png',
      datasetId: 'fixture',
      services: services,
      projection: ImageryProjection.geographic,
      tileSize: 2,
    );
    expect(xyz.tileUri(const TileCoordinate(2, 0, 1)).path, '/1/2/1.png');
    final tms = TemplateImagerySource(
      baseUri: Uri.parse('https://imagery.test/'),
      template: '{z}/{x}/{y}.png',
      datasetId: 'fixture',
      services: services,
      projection: ImageryProjection.geographic,
      urlScheme: ImageryUrlScheme.tms,
      tileSize: 2,
    );
    expect(tms.tileUri(const TileCoordinate(2, 0, 1)).path, '/1/2/0.png');
  });
  test(
    'terrain imagery reprojects north-up pixels and retains geometry',
    () async {
      final resolver = ImageryResolver();
      final base = ProceduralTerrainSource(
        scheme: TilingScheme(
          width: 1,
          rectangle: const GeographicRectangle(-.02, -.02, .02, .02),
        ),
        maximumHeight: 0,
        maximumLevel: 0,
      );
      final imagery = TemplateImagerySource(
        baseUri: Uri.parse('https://imagery.test/'),
        template: '{z}/{x}/{y}.png',
        datasetId: 'fixture',
        tileSize: 2,
        maximumLevel: 0,
        attribution: 'Fixture imagery',
        services: AssetServices(
          resolver: resolver,
          imageDecoder: ImageryDecoder(),
        ),
      );
      final source = ImageryTerrainSource(
        terrain: base,
        layers: [ImageryLayer(imagery)],
        outputSize: 8,
      );
      const coordinate = TileCoordinate(0, 0, 0);
      final loaded = await source.load(
        coordinate,
        TileLoadContext(
          sourceIdentity: source.identity,
          cancellation: TestCancellation(),
          byteBudget: source.describe(coordinate).decodedBytes,
        ),
      );
      expect(resolver.paths, ['/0/0/0.png']);
      expect(loaded.geometry.uv0!.take(2), [0, 0]);
      expect(loaded.attributions, ['Fixture imagery']);
      expect(loaded.imagery.descriptor.width, 8);
      expect(
        loaded.decodedBytes,
        lessThanOrEqualTo(source.describe(coordinate).decodedBytes),
      );
      final pixels = loaded.imagery.levels.single;
      expect(pixels[0], greaterThan(pixels[7 * 8 * 4]));
      expect(pixels[2], lessThan(pixels[7 * 8 * 4 + 2]));
      expect(loaded.geometry.positions.every((n) => n.isFinite), isTrue);
    },
  );
  test('Mercator regions clamp poles and wrap the dateline', () {
    final source = TemplateImagerySource(
      baseUri: Uri.parse('https://imagery.test/'),
      template: '{z}/{x}/{y}.png',
      datasetId: 'fixture',
      tileSize: 2,
      services: AssetServices(
        resolver: ImageryResolver(),
        imageDecoder: ImageryDecoder(),
      ),
    );
    final highLatitude = source.covering(
      GeographicRectangle(.1, math.pi / 3 - .005, .12, math.pi / 3 + .005),
      2,
    );
    expect(highLatitude.map((c) => c.y).toSet(), {2});
    final tiles = source.covering(
      const GeographicRectangle(3.1, -.1, -3.1, .1),
      2,
      maxTiles: 4,
    );
    expect(tiles.map((c) => c.x).toSet(), {0, 3});
    expect(
      source.covering(
        GeographicRectangle(0, 1.56, .1, math.pi / 2),
        2,
        maxTiles: 4,
      ),
      isEmpty,
    );
  });
}
