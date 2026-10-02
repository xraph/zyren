import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  final path = Platform.environment['ZYREN_SOURCE_LUTS'];
  test(
    'source replacement is atomic and old lighting leases survive',
    () async {
      final good = PrecomputedAtmosphereSource(
        baseUri: Directory(path!).uri,
        services: AssetServices(resolver: NativeSourceResolver()),
        format: AtmosphereLutFormat.binary,
      );
      final bad = PrecomputedAtmosphereSource(
        baseUri: Directory(path).uri,
        services: AssetServices(resolver: _Corrupt()),
        format: AtmosphereLutFormat.binary,
      );
      final backend = await NativeBackend.create();
      final plugin = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        source: good,
      );
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: Vec3(6378147, 0, 0),
          target: Vec3(6378147, 0, 1000),
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      try {
        final before = await engine.render(
          elapsed: Duration.zero,
          width: 65,
          height: 33,
        );
        final lighting = await plugin.controller.acquireLighting();
        final resident = (await backend.resourceStats()).residentBytes;
        await expectLater(
          plugin.controller.setSource(bad),
          throwsA(isA<AssetLoadException>()),
        );
        expect(plugin.controller.source, same(good));
        expect(lighting.luts.isClosed, isFalse);
        expect((await backend.resourceStats()).residentBytes, resident);
        final after = await engine.render(
          elapsed: Duration.zero,
          width: 65,
          height: 33,
        );
        expect(after.pixels, before.pixels);
        final replacement = PrecomputedAtmosphereSource(
          baseUri: Directory(path).uri,
          services: AssetServices(resolver: NativeSourceResolver()),
          format: AtmosphereLutFormat.binary,
          combinedScattering: false,
          higherOrderScattering: false,
        );
        await plugin.controller.setSource(replacement);
        expect(plugin.controller.source, same(replacement));
        expect(lighting.luts.isClosed, isFalse);
        final next = await plugin.controller.acquireLighting();
        expect(next.luts.combinedScattering, isFalse);
        expect(next.luts, isNot(same(lighting.luts)));
        await lighting.close();
        await next.close();
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 65,
          height: 33,
        );
        expect(frame.pixels.where((n) => n != 0).length, greaterThan(65 * 33));
        await plugin.controller.setParameters(AtmosphereParameters.webgpu());
        expect(plugin.controller.source, isNull);
        final generated = await plugin.controller.acquireLighting();
        expect(generated.luts.quality, AtmosphereQuality.balanced);
        expect(generated.luts.sourceScattering, isFalse);
        await generated.close();
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    skip: path == null
        ? 'Set ZYREN_SOURCE_LUTS for source replacement checks.'
        : false,
  );

  test('cache close waits for canceled physical source reads', () async {
    final resolver = _Blocked();
    final source = PrecomputedAtmosphereSource(
      baseUri: Uri.parse('fixture://source/assets/'),
      services: AssetServices(resolver: resolver),
      format: AtmosphereLutFormat.binary,
    );
    final backend = await NativeBackend.create();
    final owner = GpuScope.fromBackend(backend);
    final cache = AtmosphereLutCache(owner);
    try {
      final task = cache.acquire(parameters: source.parameters, source: source);
      final expected = expectLater(task, throwsA(isA<LoadCancelled>()));
      await resolver.started.future;
      var settled = false;
      final closing = cache.close().then((_) => settled = true);
      await resolver.canceled.future;
      expect(settled, isFalse);
      expect((await backend.resourceStats()).residentBytes, 0);
      resolver.gate.complete();
      await expected;
      await closing;
      expect(cache.entryCount, 0);
      expect(resolver.reads, 1);
    } finally {
      if (!resolver.gate.isCompleted) resolver.gate.complete();
      await cache.close();
      await owner.close();
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    }
  });
}

class _Corrupt implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    if (uri.path.endsWith('scattering.bin')) {
      return ResolvedSource(effectiveUri: uri, bytes: Uint8List(1));
    }
    return NativeSourceResolver().read(uri, context);
  }
}

class _Blocked implements ByteSourceResolver {
  final started = Completer<void>(),
      canceled = Completer<void>(),
      gate = Completer<void>();
  int reads = 0;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    started.complete();
    final subscription = context.cancellation.onCancel(
      () => canceled.complete(),
    );
    try {
      await gate.future;
      return ResolvedSource(effectiveUri: uri, bytes: Uint8List(256 * 64 * 8));
    } finally {
      subscription.dispose();
    }
  }
}
