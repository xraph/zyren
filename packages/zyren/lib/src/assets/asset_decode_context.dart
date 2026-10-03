part of 'asset_scope.dart';

/// Services for a single decode. Reads and CPU preparation are admitted serially
/// so concurrent dependencies cannot each spend the same remaining budget.
final class AssetDecodeContext {
  final AssetServices _services;
  final LoadCancellation cancellation;
  final Uri sourceUri;
  final void Function(LoadProgress) _report;
  final _sources = <Uri, Future<ResolvedSource>>{};
  Future<void> _readTail = Future.value(), _decodeTail = Future.value();
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

  bool supportsTextureEncoding(TextureEncoding encoding) =>
      _services.textureDecoder?.encodings.contains(encoding) ?? false;

  Future<TextureImageData> decodeTexture(
    Uint8List bytes, {
    required TextureEncoding encoding,
    String? fieldPath,
  }) {
    final future = _decodeTail.then((_) async {
      cancellation.throwIfCancelled();
      if (!supportsTextureEncoding(encoding)) {
        throw AssetLoadException(
          AssetLoadError.unsupportedFeature,
          'No decoder supports this texture encoding.',
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
      late final TextureImageData texture;
      try {
        decodeLimits.validateInput(bytes);
        texture = await _waitForImageDecoder(
          () => _services.textureDecoder!.decode(
            bytes,
            encoding: encoding,
            limits: decodeLimits,
          ),
        );
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
      final byteCount = texture.levels.fold<int>(
        0,
        (sum, level) => sum + level.length,
      );
      if (byteCount > decodeLimits.maxDecodedBytes ||
          texture.descriptor.width > decodeLimits.maxDimension ||
          texture.descriptor.height > decodeLimits.maxDimension) {
        throw _limit('Decoded texture exceeds its limits.', fieldPath);
      }
      reserveDecodedBytes(byteCount, fieldPath: fieldPath);
      return texture;
    });
    _decodeTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  bool supportsBufferEncoding(BufferEncoding encoding) =>
      _services.bufferDecoder?.encodings.contains(encoding) ?? false;

  bool supportsMeshEncoding(MeshEncoding encoding) =>
      _services.meshDecoder?.encodings.contains(encoding) ?? false;

  void report(LoadProgress progress) {
    cancellation.throwIfCancelled();
    _report(progress);
  }

  Future<ResolvedSource> readReference(
    String reference, {
    required Uri relativeTo,
    String? fieldPath,
  }) {
    final uri = resolveReference(
      reference,
      relativeTo: relativeTo,
      fieldPath: fieldPath,
    );
    return _read(uri, fieldPath: fieldPath);
  }

  /// Validates a deferred resource reference without downloading its content.
  Uri resolveReference(
    String reference, {
    required Uri relativeTo,
    String? fieldPath,
  }) {
    cancellation.throwIfCancelled();
    final uri = relativeTo.resolve(reference);
    _services.policy.validate(relativeTo, uri, fieldPath: fieldPath);
    return uri;
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
          httpStatus: error.httpStatus,
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
    final future = _decodeTail.then((_) async {
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
        image = await _waitForImageDecoder(
          () => decode(bytes, limits: decodeLimits),
        );
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
    _decodeTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  Future<T> _waitForImageDecoder<T>(Future<T> Function() decode) async {
    for (var attempt = 0; ; attempt++) {
      cancellation.throwIfCancelled();
      try {
        return await decode();
      } on ImageDecodeException catch (error) {
        if (error.code != ImageDecodeError.busy || attempt >= 31) rethrow;
        // Keep the encoded source while another job owns the decoder. Re-reading
        // the tile would waste bandwidth and compete for the same admission slot.
        final ready = Completer<void>();
        final timer = Timer(
          Duration(milliseconds: 4 << math.min(attempt, 4)),
          ready.complete,
        );
        final registration = cancellation.onCancel(() {
          if (!ready.isCompleted) ready.complete();
        });
        try {
          await ready.future;
        } finally {
          timer.cancel();
          registration.dispose();
        }
      }
    }
  }

  AssetLoadException _limit(String message, String? fieldPath) =>
      AssetLoadException(
        AssetLoadError.limitExceeded,
        message,
        sourceUri: sourceUri,
        fieldPath: fieldPath,
      );
  Future<Uint8List> decodeBuffer(
    Uint8List bytes, {
    required BufferDecodeOptions options,
    String? fieldPath,
  }) {
    final future = _decodeTail.then((_) async {
      cancellation.throwIfCancelled();
      if (!supportsBufferEncoding(options.encoding)) {
        throw AssetLoadException(
          AssetLoadError.unsupportedFeature,
          'No decoder is configured for this buffer encoding.',
          sourceUri: sourceUri,
          fieldPath: fieldPath,
        );
      }
      try {
        final remaining = limits.maxDecodedBytes - _decodedBytes;
        options.validateInput(bytes, maxDecodedBytes: remaining);
        final expected = options.decodedByteLength;
        reserveDecodedBytes(expected, fieldPath: fieldPath);
        final output = await _services.bufferDecoder!.decode(
          bytes,
          options: options,
          maxDecodedBytes: remaining,
        );
        cancellation.throwIfCancelled();
        if (output.length != expected) {
          throw const BufferDecodeException(
            BufferDecodeError.invalidData,
            'Buffer decoder returned a different byte count.',
          );
        }
        return output.asUnmodifiableView();
      } on BufferDecodeException catch (error) {
        throw AssetLoadException(
          switch (error.code) {
            BufferDecodeError.invalidData => AssetLoadError.invalidData,
            BufferDecodeError.limitExceeded => AssetLoadError.limitExceeded,
            BufferDecodeError.unsupportedEncoding =>
              AssetLoadError.unsupportedFeature,
            _ => AssetLoadError.decodeFailed,
          },
          error.message,
          sourceUri: sourceUri,
          fieldPath: fieldPath,
          cause: error,
        );
      }
    });
    _decodeTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  Future<DecodedMeshData> decodeMesh(
    Uint8List bytes, {
    required MeshEncoding encoding,
    String? fieldPath,
  }) {
    final future = _decodeTail.then((_) async {
      cancellation.throwIfCancelled();
      if (!supportsMeshEncoding(encoding)) {
        throw AssetLoadException(
          AssetLoadError.unsupportedFeature,
          'No decoder is configured for this mesh encoding.',
          sourceUri: sourceUri,
          fieldPath: fieldPath,
        );
      }
      final remaining = limits.maxDecodedBytes - _decodedBytes;
      if (remaining <= 0) {
        throw _limit('Decoded bytes exceed the job budget.', fieldPath);
      }
      final configured = limits.meshes;
      final decodeLimits = MeshDecodeLimits(
        maxEncodedBytes: configured.maxEncodedBytes,
        maxDecodedBytes: math.min(remaining, configured.maxDecodedBytes),
        maxVertices: configured.maxVertices,
        maxTriangles: configured.maxTriangles,
        maxAttributes: configured.maxAttributes,
      );
      try {
        decodeLimits.validateInput(bytes);
        final mesh = await _services.meshDecoder!.decode(
          bytes,
          encoding: encoding,
          limits: decodeLimits,
        );
        cancellation.throwIfCancelled();
        decodeLimits.validateOutput(mesh);
        reserveDecodedBytes(mesh.decodedByteLength, fieldPath: fieldPath);
        return mesh;
      } on BufferDecodeException catch (error) {
        throw AssetLoadException(
          switch (error.code) {
            BufferDecodeError.invalidData => AssetLoadError.invalidData,
            BufferDecodeError.limitExceeded => AssetLoadError.limitExceeded,
            BufferDecodeError.unsupportedEncoding =>
              AssetLoadError.unsupportedFeature,
            _ => AssetLoadError.decodeFailed,
          },
          error.message,
          sourceUri: sourceUri,
          fieldPath: fieldPath,
          cause: error,
        );
      }
    });
    _decodeTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }
}
