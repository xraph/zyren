part of 'asset_scope.dart';

/// Services for a single decode. Reads and image decodes are admitted serially
/// so concurrent dependencies cannot each spend the same remaining budget.
final class AssetDecodeContext {
  final AssetServices _services;
  final LoadCancellation cancellation;
  final Uri sourceUri;
  final void Function(LoadProgress) _report;
  final _sources = <Uri, Future<ResolvedSource>>{};
  Future<void> _readTail = Future.value(), _imageTail = Future.value();
  int _encodedBytes = 0, _decodedBytes = 0;
  AssetDecodeContext._(
    this._services,
    this.sourceUri,
    this.cancellation,
    this._report,
  );
  AssetLimits get limits => _services.limits;
  int get encodedBytes => _encodedBytes;
  int get decodedBytes => _decodedBytes;

  void report(LoadProgress progress) {
    cancellation.throwIfCancelled();
    _report(progress);
  }

  Future<ResolvedSource> readReference(
    String reference, {
    required Uri relativeTo,
    String? fieldPath,
  }) {
    cancellation.throwIfCancelled();
    final uri = relativeTo.resolve(reference);
    _services.policy.validate(relativeTo, uri, fieldPath: fieldPath);
    return _read(uri, fieldPath: fieldPath);
  }

  Future<ResolvedSource> _read(Uri uri, {String? fieldPath}) {
    cancellation.throwIfCancelled();
    final cached = _sources[uri];
    if (cached != null) return cached;
    if (_sources.length >= limits.maxSources) {
      throw _limit('Source count exceeds the job budget.', fieldPath);
    }
    final future = _readTail.then((_) async {
      cancellation.throwIfCancelled();
      _services.policy.validate(uri, uri, fieldPath: fieldPath);
      final remaining = limits.maxTotalSourceBytes - _encodedBytes;
      if (remaining <= 0) {
        throw _limit('Encoded bytes exceed the job budget.', fieldPath);
      }
      final maxBytes = math.min(limits.maxSourceBytes, remaining);
      try {
        final source = await _services.resolver.read(
          uri,
          SourceReadContext(
            maxBytes: maxBytes,
            cancellation: cancellation,
            policy: _services.policy,
            onProgress: (received, total) => report(
              LoadProgress(
                stage: LoadStage.fetch,
                completedBytes: received,
                totalBytes: total,
              ),
            ),
          ),
        );
        cancellation.throwIfCancelled();
        _services.policy.validate(
          uri,
          source.effectiveUri,
          fieldPath: fieldPath,
        );
        if (source.bytes.length > maxBytes) {
          throw _limit('Source exceeds its byte budget.', fieldPath);
        }
        _encodedBytes += source.bytes.length;
        return source;
      } on LoadCancelled {
        rethrow;
      } on AssetLoadException catch (error) {
        throw AssetLoadException(
          error.code,
          error.issue.message,
          sourceUri: error.issue.sourceUri ?? uri,
          fieldPath: error.fieldPath ?? fieldPath,
          cause: error,
        );
      } catch (error) {
        throw AssetLoadException(
          AssetLoadError.sourceFailed,
          'Could not read the asset source.',
          sourceUri: uri,
          fieldPath: fieldPath,
          cause: error,
        );
      }
    });
    _sources[uri] = future;
    _readTail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  /// Decoders reserve geometry and other retained payload bytes before allocating.
  void reserveDecodedBytes(int bytes, {String? fieldPath}) {
    cancellation.throwIfCancelled();
    RangeError.checkNotNegative(bytes, 'bytes');
    if (bytes > limits.maxDecodedBytes - _decodedBytes) {
      throw _limit('Decoded bytes exceed the job budget.', fieldPath);
    }
    _decodedBytes += bytes;
  }

  Future<ImageData> decodeImage(Uint8List bytes, {String? fieldPath}) =>
      _decodeImage<ImageData>(
        bytes,
        _services.imageDecoder?.decode,
        (image) => image.pixels.lengthInBytes,
        'image',
        fieldPath,
      );

  Future<HdrImageData> decodeHdrImage(Uint8List bytes, {String? fieldPath}) =>
      _decodeImage<HdrImageData>(
        bytes,
        _services.hdrImageDecoder?.decode,
        (image) => image.pixels.lengthInBytes,
        'HDR image',
        fieldPath,
      );

  Future<T> _decodeImage<T>(
    Uint8List bytes,
    Future<T> Function(Uint8List, {ImageDecodeLimits limits})? decode,
    int Function(T) byteLength,
    String kind,
    String? fieldPath,
  ) {
    final future = _imageTail.then((_) async {
      cancellation.throwIfCancelled();
      if (decode == null) {
        throw AssetLoadException(
          AssetLoadError.unsupportedFeature,
          'No $kind decoder is configured.',
          sourceUri: sourceUri,
          fieldPath: fieldPath,
        );
      }
      final remaining = limits.maxDecodedBytes - _decodedBytes;
      if (remaining <= 0) {
        throw _limit('Decoded bytes exceed the job budget.', fieldPath);
      }
      final imageLimits = limits.images;
      final decodeLimits = ImageDecodeLimits(
        maxEncodedBytes: imageLimits.maxEncodedBytes,
        maxDecodedBytes: math.min(remaining, imageLimits.maxDecodedBytes),
        maxWorkingBytes: imageLimits.maxWorkingBytes,
        maxDimension: imageLimits.maxDimension,
      );
      late final T image;
      try {
        decodeLimits.validateInput(bytes);
        image = await decode(bytes, limits: decodeLimits);
      } on ImageDecodeException catch (error) {
        throw AssetLoadException(
          switch (error.code) {
            ImageDecodeError.limitExceeded => AssetLoadError.limitExceeded,
            ImageDecodeError.invalidData => AssetLoadError.invalidData,
            ImageDecodeError.unsupportedFormat ||
            ImageDecodeError.unsupportedColor =>
              AssetLoadError.unsupportedFeature,
            _ => AssetLoadError.decodeFailed,
          },
          error.message,
          sourceUri: sourceUri,
          fieldPath: fieldPath,
          cause: error,
        );
      }
      cancellation.throwIfCancelled();
      final length = byteLength(image);
      if (length > decodeLimits.maxDecodedBytes) {
        throw _limit('Decoded image exceeds its byte budget.', fieldPath);
      }
      reserveDecodedBytes(length, fieldPath: fieldPath);
      return image;
    });
    _imageTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  AssetLoadException _limit(String message, String? fieldPath) =>
      AssetLoadException(
        AssetLoadError.limitExceeded,
        message,
        sourceUri: sourceUri,
        fieldPath: fieldPath,
      );
}
