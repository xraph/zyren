import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';

/// Bounded file and HTTP reads. Authentication and alternate URI schemes belong
/// in a host resolver. The HTTP deadline includes redirects and the response body.
final class NativeSourceResolver implements ByteSourceResolver {
  final Duration timeout;
  final int maxRedirects;
  const NativeSourceResolver({
    this.timeout = const Duration(seconds: 30),
    this.maxRedirects = 5,
  });

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    if (timeout <= Duration.zero || maxRedirects < 0) {
      throw ArgumentError(
        'Use a positive deadline and nonnegative redirect count.',
      );
    }
    context.cancellation.throwIfCancelled();
    context.policy.validate(uri, uri);
    try {
      switch (uri.scheme) {
        case 'file':
          if (uri.hasQuery) {
            throw ArgumentError('File sources cannot contain a query.');
          }
          final file = File.fromUri(uri);
          final length = await file.length();
          context.reportProgress(0, length);
          final bytes = await _collect(file.openRead(), context, length);
          return ResolvedSource(effectiveUri: uri, bytes: bytes);
        case 'http':
        case 'https':
          return await _http(uri, context);
        default:
          throw AssetLoadException(
            AssetLoadError.sourceUnavailable,
            'The native resolver supports file, HTTP and HTTPS sources.',
            sourceUri: uri,
          );
      }
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException {
      rethrow;
    } catch (error) {
      context.cancellation.throwIfCancelled();
      throw AssetLoadException(
        AssetLoadError.sourceFailed,
        'Could not read the asset source.',
        sourceUri: uri,
        cause: error,
      );
    }
  }

  Future<ResolvedSource> _http(Uri initial, SourceReadContext context) async {
    final client = HttpClient()..connectionTimeout = timeout;
    final registration = context.cancellation.onCancel(
      () => client.close(force: true),
    );
    Future<ResolvedSource> read() async {
      var uri = initial;
      for (var redirects = 0; ; redirects++) {
        context.cancellation.throwIfCancelled();
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        context.cancellation.throwIfCancelled();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen(null).cancel();
          if (location == null || redirects >= maxRedirects) {
            throw AssetLoadException(
              AssetLoadError.sourceFailed,
              'The redirect chain is missing a target or exceeds its limit.',
              sourceUri: uri,
            );
          }
          final next = uri.resolve(location);
          context.policy.validate(uri, next);
          if (next.scheme != 'http' && next.scheme != 'https') {
            throw AssetLoadException(
              AssetLoadError.forbiddenReference,
              'HTTP redirects must remain HTTP or HTTPS.',
              sourceUri: next,
            );
          }
          uri = next;
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.listen(null).cancel();
          throw AssetLoadException(
            AssetLoadError.sourceFailed,
            'Source returned HTTP ${response.statusCode}.',
            sourceUri: uri,
          );
        }
        // Content-Length counts compressed bytes when HttpClient decompresses.
        final total =
            response.contentLength >= 0 &&
                response.compressionState !=
                    HttpClientResponseCompressionState.decompressed
            ? response.contentLength
            : null;
        context.reportProgress(0, total);
        final bytes = await _collect(response, context, total);
        return ResolvedSource(
          effectiveUri: uri,
          bytes: bytes,
          mediaType: response.headers.contentType?.mimeType,
        );
      }
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('Asset source deadline exceeded.', timeout);
        },
      );
    } finally {
      registration.dispose();
      client.close(force: true);
    }
  }
}

Future<Uint8List> _collect(
  Stream<List<int>> stream,
  SourceReadContext context,
  int? total,
) async {
  context.cancellation.throwIfCancelled();
  final bytes = BytesBuilder(copy: false);
  final result = Completer<Uint8List>();
  late StreamSubscription<List<int>> subscription;
  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    result.completeError(error, stack);
    unawaited(subscription.cancel());
  }

  subscription = stream.listen(
    (chunk) {
      if (result.isCompleted) return;
      try {
        context.reportProgress(bytes.length + chunk.length, total);
        bytes.add(chunk);
      } catch (error, stack) {
        fail(error, stack);
      }
    },
    onError: (Object error, StackTrace stack) => fail(error, stack),
    onDone: () {
      if (!result.isCompleted) result.complete(bytes.takeBytes());
    },
  );
  final registration = context.cancellation.onCancel(
    () => fail(LoadCancelled()),
  );
  try {
    return await result.future;
  } finally {
    registration.dispose();
    await subscription.cancel();
  }
}
