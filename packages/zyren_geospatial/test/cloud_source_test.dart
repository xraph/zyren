import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  CloudTextureSource source(
    _Source resolver, {
    AssetLimits limits = const AssetLimits(),
    ImageDecoder? decoder,
  }) => CloudTextureSource(
    baseUri: Uri.parse('fixture://cloud/assets/?key=secret'),
    services: AssetServices(
      resolver: resolver,
      imageDecoder: decoder ?? _Images(),
      limits: limits,
    ),
  );
  test(
    'cloud source preserves linear channels, flipped image rows and volume slices',
    () async {
      final resolver = _Source();
      final data = await source(
        resolver,
      ).load(cancellation: CloudCancellation());
      expect(resolver.reads, [
        'local_weather.png',
        'shape.bin',
        'shape_detail.bin',
        'turbulence.png',
      ]);
      expect(data.maps.map((m) => (m.width, m.height, m.depth)), [
        (512, 512, 1),
        (128, 128, 128),
        (32, 32, 32),
        (128, 128, 1),
      ]);
      expect(data.maps[0].bytes.take(8), [21, 22, 23, 24, 0, 0, 0, 0]);
      expect(data.maps[0].bytes.skip(511 * 512 * 4).take(4), [1, 2, 3, 4]);
      final shape = data.maps[1].bytes.buffer.asFloat32List();
      expect(shape[0], 0);
      expect(shape[1], closeTo(1 / 255, 1e-9));
      expect(shape[128 * 128], 1);
      expect(data.decodedBytes, 9633792);
      expect(() => data.maps.clear(), throwsUnsupportedError);
      expect(() => data.maps[0].bytes[0] = 0, throwsUnsupportedError);
    },
  );
  test(
    'cloud source rejects limits, corrupt dimensions and redirected endpoints',
    () async {
      final resolver = _Source();
      await expectLater(
        source(
          resolver,
          limits: AssetLimits(maxDecodedBytes: 100),
        ).load(cancellation: CloudCancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      expect(resolver.reads, isEmpty);
      for (final fault in ['redirect', 'volume', 'oversized', 'error']) {
        resolver.fault = fault;
        await expectLater(
          source(resolver).load(cancellation: CloudCancellation()),
          throwsA(
            isA<AssetLoadException>().having(
              (e) => e.toString().contains('secret'),
              'secret free',
              false,
            ),
          ),
        );
      }
      resolver.fault = '';
      await expectLater(
        source(
          resolver,
          decoder: _Images(wrongSize: true),
        ).load(cancellation: CloudCancellation()),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );
  test(
    'cloud source admission holds physical reads after cancellation',
    () async {
      final resolver = _Source()..gate = Completer<void>();
      final loader = source(resolver);
      final signals = [for (var i = 0; i < 10; i++) CloudCancellation()];
      var settled = 0;
      final pending = [
        for (final signal in signals)
          expectLater(
            loader.load(cancellation: signal).whenComplete(() => settled++),
            throwsA(isA<LoadCancelled>()),
          ),
      ];
      await resolver.started.future;
      await expectLater(
        loader.load(cancellation: CloudCancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      for (final signal in signals) {
        signal.cancel();
      }
      await Future<void>.delayed(Duration.zero);
      expect(settled, 0);
      expect(resolver.reads.length, 2);
      resolver.gate!.complete();
      await Future.wait(pending);
      expect(resolver.reads.length, 2);
    },
  );
  final path = Platform.environment['ZYREN_SOURCE_CLOUDS'];
  test(
    'pinned source cloud maps upload and render with native atmospheric light',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final source = CloudTextureSource(
        baseUri: Directory(path!).uri,
        services: AssetServices(
          resolver: NativeSourceResolver(),
          imageDecoder: NativeImageDecoder(),
        ),
      );
      final loaded = await CloudTextures.load(
        owner,
        source,
        cancellation: CloudCancellation(),
      );
      expect((await backend.resourceStats()).residentBytes, 10005160);
      final date = DateTime.utc(2026, 3, 20, 12),
          sun = CelestialDirections.at(DateTime.utc(2026, 3, 20, 12)).sunECEF;
      final air = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final clouds = CloudPlugin(
        textures: loaded.textures,
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 16,
      );
      final engine = await SceneEngine.create(
        scene: Scene()..renderSettings = RenderSettings(hdr: true),
        camera: PerspectiveCamera(
          position: sun * 6360100,
          target: sun * 6363000,
          up: const Vec3(0, 0, 1),
          near: 1,
          far: 1e7,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [air, clouds],
      );
      try {
        await loaded.close();
        await owner.close();
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 31,
          height: 31,
        );
        final alpha = [
          for (var i = 3; i < frame.pixels.length; i += 4) frame.pixels[i],
        ];
        expect(alpha.where((v) => v > 10).length, greaterThan(50));
        expect(alpha.toSet().length, greaterThan(5));
      } finally {
        await owner.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    skip: path == null
        ? 'Set ZYREN_SOURCE_CLOUDS for pinned source cloud assets.'
        : false,
    timeout: Timeout(Duration(minutes: 3)),
  );
}

class CloudCancellation implements LoadCancellation {
  @override
  bool isCancelled = false;
  final callbacks = <void Function()>[];
  void cancel() {
    isCancelled = true;
    for (final callback in List.of(callbacks)) {
      callback();
    }
  }

  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    callbacks.add(callback);
    return Registration(() => callbacks.remove(callback));
  }
}

class _Source implements ByteSourceResolver {
  final reads = <String>[];
  String fault = '';
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    final name = uri.pathSegments.last;
    reads.add(name);
    if (!started.isCompleted) started.complete();
    await gate?.future;
    if (fault == 'error') throw StateError('secret endpoint');
    final size = name == 'shape.bin'
        ? 128
        : name == 'shape_detail.bin'
        ? 32
        : 0;
    final data = size > 0
        ? Uint8List(size * size * size)
        : Uint8List.fromList([name == 'local_weather.png' ? 0 : 1]);
    if (size > 0) {
      data[1] = 1;
      data[size * size] = 255;
    }
    return ResolvedSource(
      effectiveUri: fault == 'redirect'
          ? Uri.parse('https://other/?secret')
          : uri,
      bytes: fault == 'oversized'
          ? Uint8List(context.maxBytes + 1)
          : fault == 'volume' && size > 0
          ? Uint8List(1)
          : data,
    );
  }
}

class _Images implements ImageDecoder {
  final bool wrongSize;
  _Images({this.wrongSize = false});
  @override
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    final size = wrongSize
        ? 1
        : bytes[0] == 0
        ? 512
        : 128;
    final data = Uint8List(size * size * 4);
    data.setAll(0, [1, 2, 3, 4]);
    data.setAll((size - 1) * size * 4, [21, 22, 23, 24]);
    return ImageData(pixels: data, size: PhysicalSize(size, size));
  }
}
