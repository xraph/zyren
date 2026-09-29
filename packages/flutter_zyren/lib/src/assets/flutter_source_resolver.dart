import 'dart:async';
import 'package:flutter/services.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

/// Resolves asset:/// keys through a Flutter bundle and delegates other schemes.
/// Bundle APIs load a whole entry; its size is checked before making our copy.
final class FlutterSourceResolver implements ByteSourceResolver {
  final AssetBundle? bundle;
  final ByteSourceResolver uriResolver;
  const FlutterSourceResolver({
    this.bundle,
    this.uriResolver = const NativeSourceResolver(),
  });
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    if (uri.scheme != 'asset') return uriResolver.read(uri, context);
    context.cancellation.throwIfCancelled();
    if (uri.hasAuthority && uri.authority.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith('/') ||
        uri.pathSegments.isEmpty ||
        uri.pathSegments.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.contains('/') ||
              part.contains('\\'),
        )) {
      throw AssetLoadException(
        AssetLoadError.forbiddenReference,
        'Use a bundle key below asset:/// without traversal, a query or an authority.',
        sourceUri: uri,
      );
    }
    final cancelled = Completer<ByteData>();
    final registration = context.cancellation.onCancel(
      () => cancelled.completeError(LoadCancelled()),
    );
    try {
      context.reportProgress(0);
      final data = await Future.any([
        (bundle ?? rootBundle).load(uri.pathSegments.join('/')),
        cancelled.future,
      ]);
      context.cancellation.throwIfCancelled();
      context.reportProgress(data.lengthInBytes, data.lengthInBytes);
      return ResolvedSource(
        effectiveUri: uri,
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      registration.dispose();
    }
  }
}
