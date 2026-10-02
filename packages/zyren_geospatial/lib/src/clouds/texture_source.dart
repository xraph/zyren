import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// One source map, ready for linear GPU upload. Volume samples are float32.
final class CloudTexturePixels {
  final int width, height, depth;
  final Uint8List bytes;
  CloudTexturePixels._(this.width, this.height, this.depth, Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();
}

/// Weather, shape, detail and turbulence in source binding order.
final class CloudTextureData {
  final List<CloudTexturePixels> maps;
  CloudTextureData._(List<CloudTexturePixels> maps)
    : maps = List.unmodifiable(maps);
  int get decodedBytes => maps.fold(0, (n, m) => n + m.bytes.length);
}

/// Loads the source's fixed-size PNG and raw R8 cloud maps through your resolver.
/// Two jobs can run at once, with eight waiting. Cancellation waits for physical
/// reads and decodes before releasing admission. No partial set is published.
final class CloudTextureSource {
  final Uri _base;
  final AssetServices _services;
  CloudTextureSource({required Uri baseUri, required AssetServices services})
    : _base = baseUri,
      _services = services {
    services.limits.validate();
    if (!baseUri.hasScheme ||
        baseUri.hasFragment ||
        baseUri.userInfo.isNotEmpty ||
        !baseUri.path.endsWith('/')) {
      throw ArgumentError('Cloud source requires an absolute directory URI.');
    }
  }
  factory CloudTextureSource.upstream({
    required AssetServices services,
  }) => CloudTextureSource(
    baseUri: Uri.parse(
      'https://media.githubusercontent.com/media/takram-design-engineering/three-geospatial/45a1c6c1bb9fd38b3680fd120795ff4c32df68ff/packages/clouds/assets/',
    ),
    services: services,
  );
  static const _files = [
    ('local_weather.png', 512, false),
    ('shape.bin', 128, true),
    ('shape_detail.bin', 32, true),
    ('turbulence.png', 128, false),
  ];
  static const decodedBytes = 9633792;
  Future<CloudTextureData> load({required LoadCancellation cancellation}) =>
      _Admission.run(() async {
        final limits = _services.limits;
        if (decodedBytes > limits.maxDecodedBytes || limits.maxSources < 4) {
          throw _failure(AssetLoadError.limitExceeded);
        }
        final decoder = _services.imageDecoder;
        if (decoder == null) {
          throw _failure(AssetLoadError.unsupportedFeature);
        }
        var encoded = 0;
        final maps = <CloudTexturePixels>[];
        try {
          for (final (name, size, volume) in _files) {
            cancellation.throwIfCancelled();
            final uri = _base.resolve(name);
            _services.policy.validate(_base, uri);
            final maximum = math.min(
              volume ? size * size * size : 2 * 1024 * 1024,
              math.min(
                limits.maxSourceBytes,
                math.min(8 * 1024 * 1024, limits.maxTotalSourceBytes) - encoded,
              ),
            );
            if (maximum <= 0) {
              throw _failure(AssetLoadError.limitExceeded);
            }
            final result = await _services.resolver.read(
              uri,
              SourceReadContext(
                maxBytes: maximum,
                cancellation: cancellation,
                policy: _services.policy,
                onProgress: (_, _) {},
              ),
            );
            cancellation.throwIfCancelled();
            _services.policy.validate(uri, result.effectiveUri);
            if (result.bytes.length > maximum) {
              throw _failure(AssetLoadError.limitExceeded);
            }
            encoded += result.bytes.length;
            if (volume) {
              if (result.bytes.length != size * size * size) {
                throw _failure(AssetLoadError.invalidData);
              }
              maps.add(await _VolumeJob(result.bytes, size).run());
            } else {
              final imageLimits = limits.images;
              if (size > imageLimits.maxDimension ||
                  size * size * 4 > imageLimits.maxDecodedBytes) {
                throw _failure(AssetLoadError.limitExceeded);
              }
              final options = ImageDecodeLimits(
                maxEncodedBytes: math.min(maximum, imageLimits.maxEncodedBytes),
                maxDecodedBytes: size * size * 4,
                maxDimension: size,
                maxWorkingBytes: imageLimits.maxWorkingBytes,
              );
              options.validateInput(result.bytes);
              final image = await decoder.decode(result.bytes, limits: options);
              cancellation.throwIfCancelled();
              if (image.size.width != size ||
                  image.size.height != size ||
                  image.pixels.length > imageLimits.maxDecodedBytes ||
                  image.alphaMode == AlphaMode.premultiplied) {
                throw _failure(AssetLoadError.invalidData);
              }
              maps.add(await _ImageJob(image, size).run());
            }
            cancellation.throwIfCancelled();
          }
          return CloudTextureData._(maps);
        } on LoadCancelled {
          rethrow;
        } on AssetLoadException catch (e) {
          throw _failure(e.code);
        } on ImageDecodeException catch (e) {
          throw _failure(
            e.code == ImageDecodeError.limitExceeded
                ? AssetLoadError.limitExceeded
                : AssetLoadError.invalidData,
          );
        } catch (_) {
          cancellation.throwIfCancelled();
          throw _failure(AssetLoadError.sourceFailed);
        }
      }, cancellation);
}

final class _VolumeJob {
  final Uint8List bytes;
  final int size;
  _VolumeJob(this.bytes, this.size);
  Future<CloudTexturePixels> run() => Isolate.run(() {
    final floats = Float32List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      floats[i] = bytes[i] / 255;
    }
    return CloudTexturePixels._(size, size, size, floats.buffer.asUint8List());
  });
}

final class _ImageJob {
  final ImageData image;
  final int size;
  _ImageJob(this.image, this.size);
  Future<CloudTexturePixels> run() => Isolate.run(() {
    final result = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final source = y * image.rowStride + x * 4,
            target = ((size - 1 - y) * size + x) * 4;
        for (var c = 0; c < 4; c++) {
          result[target + c] =
              image.pixels[source +
                  (image.format == PixelFormat.bgra8 && c < 3 ? 2 - c : c)];
        }
      }
    }
    return CloudTexturePixels._(size, size, 1, result);
  });
}

abstract final class _Admission {
  static int active = 0;
  static final queue = Queue<Completer<void>>();
  static Future<T> run<T>(
    Future<T> Function() action,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    if (active < 2) {
      active++;
    } else {
      if (queue.length >= 8) {
        throw _failure(AssetLoadError.limitExceeded);
      }
      final gate = Completer<void>();
      queue.add(gate);
      await gate.future;
    }
    try {
      cancellation.throwIfCancelled();
      return await action();
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
    AssetLoadException(code, 'Cloud texture source could not be loaded.');

/// Loads pinned STBN samples through your asset services. Override [uri] for
/// a local fixture or an authorized mirror.
final class CloudBlueNoiseSource {
  final AssetServices services;
  final Uri? uri;
  const CloudBlueNoiseSource({required this.services, this.uri});
  Future<CloudBlueNoise> load({required LoadCancellation cancellation}) =>
      CloudBlueNoise.load(
        services: services,
        cancellation: cancellation,
        uri: uri,
      );
}

/// Source STBN samples, 128 by 128 by 64 unsigned bytes. Kept outside textures so
/// temporal jitter does not consume another sampled-texture binding.
final class CloudBlueNoise {
  final Uint8List bytes;
  CloudBlueNoise(Uint8List bytes) : bytes = _copy(bytes);
  static Uint8List _copy(Uint8List bytes) {
    if (bytes.length != 1048576) {
      throw ArgumentError('Cloud blue noise requires 128x128x64 bytes.');
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  static Future<CloudBlueNoise> load({
    required AssetServices services,
    required LoadCancellation cancellation,
    Uri? uri,
  }) => _Admission.run(() async {
    services.limits.validate();
    final target =
        uri ??
        Uri.parse(
          'https://media.githubusercontent.com/media/takram-design-engineering/three-geospatial/9627216cc50057994c98a2118f3c4a23765d43b9/packages/core/assets/stbn.bin',
        );
    final limits = services.limits;
    if (limits.maxSourceBytes < 1048576 ||
        limits.maxTotalSourceBytes < 1048576 ||
        limits.maxDecodedBytes < 1048576) {
      throw _failure(AssetLoadError.limitExceeded);
    }
    try {
      services.policy.validate(target, target);
      final result = await services.resolver.read(
        target,
        SourceReadContext(
          maxBytes: 1048576,
          cancellation: cancellation,
          policy: services.policy,
          onProgress: (_, _) {},
        ),
      );
      cancellation.throwIfCancelled();
      services.policy.validate(target, result.effectiveUri);
      if (result.bytes.length != 1048576) {
        throw _failure(AssetLoadError.invalidData);
      }
      return CloudBlueNoise(result.bytes);
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (e) {
      throw _failure(e.code);
    } catch (_) {
      cancellation.throwIfCancelled();
      throw _failure(AssetLoadError.sourceFailed);
    }
  }, cancellation);
}
