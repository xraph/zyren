import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'source admission bounds active jobs and drains canceled queued work',
    () async {
      final resolver = _Tables()..gate = Completer<void>();
      final source = PrecomputedAtmosphereSource(
        baseUri: Uri.parse('fixture://tables/assets/'),
        services: AssetServices(resolver: resolver),
        format: AtmosphereLutFormat.binary,
      );
      final signals = [for (var i = 0; i < 10; i++) _Cancellation()];
      final jobs = [
        for (final signal in signals)
          expectLater(
            source.load(cancellation: signal),
            throwsA(isA<LoadCancelled>()),
          ),
      ];
      await resolver.started.future;
      await expectLater(
        source.load(cancellation: _Cancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      expect(resolver.reads.length, 2);
      for (final signal in signals) {
        signal.cancel();
      }
      resolver.gate!.complete();
      await Future.wait(jobs);
      expect(resolver.reads.length, 2);
    },
  );
  test(
    'complete source sets retain their layout and optional channels',
    () async {
      for (final combined in [true, false]) {
        for (final higher in [true, false]) {
          final resolver = _Tables();
          final source = PrecomputedAtmosphereSource(
            baseUri: Uri.parse('fixture://tables/assets/'),
            services: AssetServices(resolver: resolver),
            format: AtmosphereLutFormat.binary,
            combinedScattering: combined,
            higherOrderScattering: higher,
          );
          final tables = await source.load(cancellation: _Cancellation());
          expect(
            tables.tables.keys,
            unorderedEquals([
              'transmittance',
              'irradiance',
              'scattering',
              if (!combined) 'single_mie_scattering',
              if (higher) 'higher_order_scattering',
            ]),
          );
          expect(tables.tables['scattering']!.width, 256);
          expect(tables.tables['scattering']!.height, 128);
          expect(tables.tables['scattering']!.depth, 32);
          expect(tables.decodedBytes, source.decodedBytes);
          expect(tables.parameters.key, AtmosphereParameters.legacy().key);
          expect(() => tables.tables.clear(), throwsUnsupportedError);
        }
      }
    },
  );
  test(
    'source limits and redirect policy are enforced and errors hide endpoints',
    () async {
      final resolver = _Tables();
      final small = PrecomputedAtmosphereSource(
        baseUri: Uri.parse('fixture://tables/assets/?key=secret'),
        services: AssetServices(
          resolver: resolver,
          limits: AssetLimits(maxDecodedBytes: 100),
        ),
      );
      await expectLater(
        small.load(cancellation: _Cancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      expect(resolver.reads, isEmpty);
      resolver.redirect = true;
      final source = PrecomputedAtmosphereSource(
        baseUri: Uri.parse('fixture://tables/assets/?key=secret'),
        services: AssetServices(resolver: resolver),
        format: AtmosphereLutFormat.binary,
      );
      await expectLater(
        source.load(cancellation: _Cancellation()),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.forbiddenReference)
              .having(
                (e) => e.toString().contains('secret'),
                'redaction',
                false,
              ),
        ),
      );
      resolver.redirect = false;
      resolver.oversized = true;
      await expectLater(
        source.load(cancellation: _Cancellation()),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    },
  );
  test(
    'canceling a source waits for its physical read and stops subsequent tables',
    () async {
      final resolver = _Tables()..gate = Completer<void>();
      final source = PrecomputedAtmosphereSource(
        baseUri: Uri.parse('fixture://tables/assets/'),
        services: AssetServices(resolver: resolver),
        format: AtmosphereLutFormat.binary,
      );
      final cancel = _Cancellation();
      var settled = false;
      final load = source.load(cancellation: cancel);
      final expected = expectLater(load, throwsA(isA<LoadCancelled>()));
      final observed = load.then<void>(
        (_) => settled = true,
        onError: (Object _) {
          settled = true;
        },
      );
      await resolver.started.future;
      cancel.cancel();
      await Future<void>.delayed(Duration(milliseconds: 30));
      expect(settled, isFalse);
      resolver.gate!.complete();
      await expected;
      await observed;
      expect(resolver.reads.length, 1);
      expect(settled, isTrue);
    },
  );
}

final class _Tables implements ByteSourceResolver {
  final reads = <Uri>[];
  final started = Completer<void>();
  Completer<void>? gate;
  bool redirect = false, oversized = false;
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri);
    if (!started.isCompleted) started.complete();
    await gate?.future;
    final name = uri.pathSegments.last;
    final bytes = name.startsWith('transmittance')
        ? 256 * 64 * 8
        : name.startsWith('irradiance')
        ? 64 * 16 * 8
        : 256 * 128 * 32 * 8;
    return ResolvedSource(
      effectiveUri: redirect
          ? Uri.parse('fixture://other/leak?key=secret')
          : uri,
      bytes: Uint8List(oversized ? context.maxBytes + 1 : bytes),
    );
  }
}

final class _Cancellation implements LoadCancellation {
  final callbacks = <void Function()>{};
  @override
  bool isCancelled = false;
  void cancel() {
    isCancelled = true;
    for (final callback in callbacks.toList()) {
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
    if (isCancelled) callback();
    return Registration(() => callbacks.remove(callback));
  }
}
