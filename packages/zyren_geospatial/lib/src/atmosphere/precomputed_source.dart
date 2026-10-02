import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'parameters.dart';
import 'table_decoder.dart';

/// Immutable CPU tables. GPU upload leaves their bytes unchanged.
final class PrecomputedAtmosphereTables {
  final AtmosphereParameters parameters;
  final bool combinedScattering, higherOrderScattering;
  final Map<String, AtmosphereTable> tables;
  PrecomputedAtmosphereTables._(
    this.parameters,
    this.combinedScattering,
    this.higherOrderScattering,
    Map<String, AtmosphereTable> tables,
  ) : tables = Map.unmodifiable(tables);
  int get decodedBytes => tables.values.fold(0, (n, t) => n + t.bytes.length);
}

/// Source-compatible 256x128x32 scattering tables over your asset resolver.
/// Parameters must describe the precomputation that produced these files.
/// Each load reads sequentially and retains its admission until physical work
/// settles, including after cancellation. A set publishes only when complete.
final class PrecomputedAtmosphereSource {
  final Uri _base;
  final AssetServices _services;
  final AtmosphereParameters parameters;
  final AtmosphereLutFormat format;
  final bool combinedScattering, higherOrderScattering;
  PrecomputedAtmosphereSource({
    required Uri baseUri,
    required AssetServices services,
    AtmosphereParameters? parameters,
    this.format = AtmosphereLutFormat.exr,
    this.combinedScattering = true,
    this.higherOrderScattering = true,
  }) : _base = baseUri,
       _services = services,
       parameters = parameters ?? AtmosphereParameters.legacy() {
    services.limits.validate();
    if (!baseUri.hasScheme ||
        baseUri.hasFragment ||
        baseUri.userInfo.isNotEmpty ||
        !baseUri.path.endsWith('/')) {
      throw ArgumentError(
        'Atmosphere source requires an absolute directory URI.',
      );
    }
    if (combinedScattering &&
        (this.parameters.rayleighScattering.storage.any((n) => n <= 0) ||
            this.parameters.mieScattering.x <= 0)) {
      throw ArgumentError(
        'Packed atmosphere tables require positive scattering coefficients.',
      );
    }
  }
  factory PrecomputedAtmosphereSource.upstream({
    required AssetServices services,
    AtmosphereLutFormat format = AtmosphereLutFormat.exr,
    bool combinedScattering = true,
    bool higherOrderScattering = true,
  }) => PrecomputedAtmosphereSource(
    baseUri: Uri.parse(
      'https://media.githubusercontent.com/media/takram-design-engineering/three-geospatial/eac103980f20c0956f2d3215833e73514be08462/packages/atmosphere/assets/',
    ),
    services: services,
    format: format,
    combinedScattering: combinedScattering,
    higherOrderScattering: higherOrderScattering,
  );
  List<(String, int, int, int)> get _files => [
    ('transmittance', 256, 64, 1),
    ('irradiance', 64, 16, 1),
    ('scattering', 256, 128, 32),
    if (!combinedScattering) ('single_mie_scattering', 256, 128, 32),
    if (higherOrderScattering) ('higher_order_scattering', 256, 128, 32),
  ];
  int get decodedBytes => _files.fold(0, (n, f) => n + f.$2 * f.$3 * f.$4 * 8);

  Future<PrecomputedAtmosphereTables> load({
    required LoadCancellation cancellation,
  }) => _TableAdmission.run(() async {
    cancellation.throwIfCancelled();
    final limits = _services.limits;
    if (decodedBytes > math.min(32 * 1024 * 1024, limits.maxDecodedBytes) ||
        _files.length > limits.maxSources) {
      throw _failure(AssetLoadError.limitExceeded);
    }
    final result = <String, AtmosphereTable>{};
    var totalEncoded = 0;
    try {
      for (final (name, width, height, depth) in _files) {
        cancellation.throwIfCancelled();
        final uri = _base.resolve(
          '$name.${format == AtmosphereLutFormat.binary ? 'bin' : 'exr'}',
        );
        _services.policy.validate(_base, uri);
        final maximum = math.min(
          16 * 1024 * 1024,
          math.min(
            limits.maxSourceBytes,
            math.min(32 * 1024 * 1024, limits.maxTotalSourceBytes) -
                totalEncoded,
          ),
        );
        if (maximum <= 0) throw _failure(AssetLoadError.limitExceeded);
        final resolved = await _services.resolver.read(
          uri,
          SourceReadContext(
            maxBytes: maximum,
            cancellation: cancellation,
            policy: _services.policy,
            onProgress: (_, _) {},
          ),
        );
        cancellation.throwIfCancelled();
        _services.policy.validate(uri, resolved.effectiveUri);
        if (resolved.bytes.length > maximum) {
          throw _failure(AssetLoadError.limitExceeded);
        }
        totalEncoded += resolved.bytes.length;
        // Only this CPU record crosses the isolate boundary, never a GPU scope.
        final job = _TableJob(
          resolved.bytes,
          format,
          width,
          height,
          depth,
          maximum,
        );
        result[name] = await job.run();
        cancellation.throwIfCancelled();
      }
      return PrecomputedAtmosphereTables._(
        parameters,
        combinedScattering,
        higherOrderScattering,
        result,
      );
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (error) {
      throw _failure(error.code);
    } catch (_) {
      cancellation.throwIfCancelled();
      throw _failure(AssetLoadError.sourceFailed);
    }
  }, cancellation);
}

final class _TableJob {
  final Uint8List bytes;
  final AtmosphereLutFormat format;
  final int width, height, depth, maximum;
  _TableJob(
    this.bytes,
    this.format,
    this.width,
    this.height,
    this.depth,
    this.maximum,
  );
  Future<AtmosphereTable> run() => Isolate.run(
    () => AtmosphereTableDecoder(
      maxEncodedBytes: maximum,
      maxDecodedBytes: width * height * depth * 8,
    ).decode(bytes, format: format, width: width, height: height, depth: depth),
  );
}

abstract final class _TableAdmission {
  static int active = 0;
  static final queue = Queue<Completer<void>>();
  static Future<T> run<T>(
    Future<T> Function() work,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (active < 2) {
      active++;
    } else {
      if (queue.length >= 8) throw _failure(AssetLoadError.limitExceeded);
      final gate = Completer<void>();
      queue.add(gate);
      await gate.future;
    }
    try {
      cancellation.throwIfCancelled();
      return await work();
    } finally {
      if (queue.isEmpty) {
        active--;
      } else {
        queue.removeFirst().complete();
      }
    }
  }
}

AssetLoadException _failure(AssetLoadError code) =>
    AssetLoadException(code, 'Atmosphere table source could not be loaded.');
