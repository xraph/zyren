part of '../zyren_3d_tiles.dart';

final class TileAttribution3D {
  final String html;
  final bool collapsible;
  const TileAttribution3D({required this.html, this.collapsible = true});
}

/// Caller-owned credentials are exchanged outside the scene and render loop.
abstract final class Tiles3DProvider {
  static Future<Tiles3DProviderSession> googleMaps({
    required ByteSourceResolver transport,
    required FutureOr<String> Function() apiKey,
  }) => _open(Tiles3DProviderSession._(transport, apiKey, null));

  static Future<Tiles3DProviderSession> cesiumIon({
    required ByteSourceResolver transport,
    required FutureOr<String> Function() accessToken,
    required int assetId,
  }) {
    RangeError.checkValueInInterval(assetId, 1, 0x1fffffffffffff);
    return _open(Tiles3DProviderSession._(transport, accessToken, assetId));
  }

  static Future<Tiles3DProviderSession> _open(
    Tiles3DProviderSession value,
  ) async {
    try {
      await value._refresh();
      return value;
    } catch (_) {
      await value.close();
      rethrow;
    }
  }
}

/// A resolver and its renewable provider session. Close after all scene scopes.
final class Tiles3DProviderSession implements ByteSourceResolver {
  final ByteSourceResolver _transport;
  final FutureOr<String> Function() _credential;
  final int? _assetId;
  final _lifetime = _ProviderCancellation();
  final _physical = <Future<ResolvedSource>>{};
  Future<void>? _refreshing, _closing;
  Uri? _root;
  String _key = '', _bearer = '';
  String? _session;
  int _generation = 0;
  bool _google = false;
  ResolvedSource? _initialRoot;
  List<TileAttribution3D> _credits = const [];
  Tiles3DProviderSession._(this._transport, this._credential, this._assetId);

  Uri get rootUri => _root!;
  bool get isGoogleMaps => _google;
  List<TileAttribution3D> get attributions => _credits;

  Future<void> _refresh() => _refreshing ??= _refreshImpl().whenComplete(() {
    _refreshing = null;
  });

  Future<void> _refreshImpl() async {
    _lifetime.throwIfCancelled();
    final String credential;
    try {
      credential = await _credential();
    } catch (_) {
      throw AssetLoadException(
        AssetLoadError.sourceUnavailable,
        'Provider credentials are unavailable.',
      );
    }
    if (credential.isEmpty || credential.length > 16384) _invalid();
    Uri root;
    var key = '', bearer = '', google = true;
    var credits = <TileAttribution3D>[];
    final asset = _assetId;
    if (asset == null) {
      root = Uri.parse('https://tile.googleapis.com/v1/3dtiles/root.json');
      key = credential;
    } else {
      final endpoint = Uri.https(
        'api.cesium.com',
        '/v1/assets/$asset/endpoint',
        {'access_token': credential},
      );
      final source = await _send(endpoint, _internalContext(), const {});
      final data = _json(source.bytes, 1024 * 1024, 32);
      if (data['type'] != '3DTILES') _unsupported();
      if (data.containsKey('externalType')) {
        if (data['externalType'] != '3DTILES') _unsupported();
        final value = _object(data['options'])['url'];
        root = _providerUri(value);
        if (root.host != 'tile.googleapis.com') _unsupported();
        key = root.queryParameters['key'] ?? '';
        if (key.isEmpty) _invalid();
      } else {
        google = false;
        root = _providerUri(data['url']);
        final value = data['accessToken'];
        if (value is! String || value.isEmpty || value.length > 16384) {
          _invalid();
        }
        bearer = value;
      }
      final attributes = data['attributions'] ?? [];
      if (attributes is! List || attributes.length > 256) _limit();
      for (final value in attributes) {
        final item = _object(value), html = item['html'];
        if (html is! String || html.length > 65536) _invalid();
        final collapsible = item['collapsible'] ?? true;
        if (collapsible is! bool) _invalid();
        credits.add(TileAttribution3D(html: html, collapsible: collapsible));
      }
    }
    root = _publicUri(root);
    // Existing node references cannot safely migrate to a new provider origin.
    if (_root != null && !_sameOrigin(_root!, root)) _forbiddenProvider();
    final query = {...root.queryParameters, if (google) 'key': key};
    final source = await _send(
      root.replace(queryParameters: query),
      _internalContext(),
      {if (!google) 'Authorization': 'Bearer $bearer'},
    );
    final json = _json(source.bytes, 4 * 1024 * 1024, 160);
    final session = google ? _findSession(json) : null;
    _lifetime.throwIfCancelled();
    _key = key;
    _bearer = bearer;
    _google = google;
    _session = session;
    _root = root;
    _credits = List.unmodifiable(credits);
    _initialRoot = _sanitize(source);
    _generation++;
  }

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    _lifetime.throwIfCancelled();
    context.cancellation.throwIfCancelled();
    if (!_sameOrigin(rootUri, uri)) _forbiddenProvider();
    context.policy.validate(rootUri, uri);
    await _refreshing;
    context.cancellation.throwIfCancelled();
    _lifetime.throwIfCancelled();
    if (_publicUri(uri) == rootUri) {
      if (_initialRoot == null) await _refresh();
      context.cancellation.throwIfCancelled();
      _lifetime.throwIfCancelled();
      final source = _initialRoot!;
      _initialRoot = null;
      context.reportProgress(source.bytes.length, source.bytes.length);
      return source;
    }
    final generation = _generation;
    for (var attempt = 0; ; attempt++) {
      final query = {...uri.queryParameters}
        ..remove('key')
        ..remove('access_token')
        ..remove('session');
      if (_google) {
        query['key'] = _key;
        if (_session != null) query['session'] = _session!;
      } else if (rootUri.queryParameters['v'] case final version?) {
        query['v'] = version;
      }
      try {
        final source = await _send(
          uri.replace(queryParameters: query),
          context,
          {if (!_google) 'Authorization': 'Bearer $_bearer'},
        );
        return _sanitize(source);
      } on AssetLoadException catch (error) {
        if (attempt != 0 || ![401, 403].contains(error.httpStatus)) rethrow;
        // A sibling may already have refreshed the same failed generation.
        if (generation == _generation) {
          await _refresh();
        } else {
          await _refreshing;
        }
        context.cancellation.throwIfCancelled();
        _lifetime.throwIfCancelled();
      }
    }
  }

  SourceReadContext _internalContext() => SourceReadContext(
    maxBytes: 4 * 1024 * 1024,
    cancellation: _lifetime,
    policy: const SourcePolicy(),
    onProgress: (_, _) {},
  );

  Future<ResolvedSource> _send(
    Uri uri,
    SourceReadContext parent,
    Map<String, String> headers,
  ) async {
    final cancellation = _JoinedProviderCancellation(
      parent.cancellation,
      _lifetime,
    );
    cancellation.throwIfCancelled();
    final context = SourceReadContext(
      maxBytes: parent.maxBytes,
      cancellation: cancellation,
      policy: _ProviderPolicy(parent.policy),
      headers: headers,
      onProgress: parent.reportProgress,
    );
    Future<ResolvedSource>? pending;
    try {
      pending = _transport.read(uri, context);
      _physical.add(pending);
      final source = await pending;
      cancellation.throwIfCancelled();
      context.policy.validate(uri, source.effectiveUri);
      if (source.bytes.length > context.maxBytes) _limit();
      return source;
    } on LoadCancelled {
      rethrow;
    } catch (error) {
      cancellation.throwIfCancelled();
      // Transport causes and URIs may contain credentials. Never retain them.
      throw AssetLoadException(
        error is AssetLoadException ? error.code : AssetLoadError.sourceFailed,
        'Provider request failed.',
        httpStatus: error is AssetLoadException ? error.httpStatus : null,
      );
    } finally {
      if (pending != null) _physical.remove(pending);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _lifetime.cancel();
    final refresh = _refreshing;
    await Future.wait([
      for (final request in [..._physical])
        request.then<void>((_) {}, onError: (Object _) {}),
      if (refresh != null) refresh.then<void>((_) {}, onError: (Object _) {}),
    ]);
    _initialRoot = null;
    _key = _bearer = '';
    _session = null;
  }
}

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme &&
    a.host == b.host &&
    a.port == b.port &&
    b.userInfo.isEmpty &&
    !b.hasFragment;
Uri _providerUri(Object? value) {
  if (value is! String || value.length > 16384) _invalid();
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port != 443) {
    _invalid();
  }
  return uri;
}

Uri _publicUri(Uri uri) {
  final query = {...uri.queryParameters}
    ..remove('key')
    ..remove('access_token')
    ..remove('session');
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
  );
}

ResolvedSource _sanitize(ResolvedSource source) => ResolvedSource(
  effectiveUri: _publicUri(source.effectiveUri),
  bytes: source.bytes,
  mediaType: source.mediaType,
  headers: source.headers,
);
String? _findSession(Map<String, dynamic> json) {
  final queue = <Map<String, dynamic>>[_object(json['root'])];
  var visited = 0;
  while (queue.isNotEmpty) {
    if (++visited > 32768) _limit();
    final node = queue.removeLast();
    final content = node['content'];
    if (content != null) {
      final uri = _object(content)['uri'];
      if (uri is String) {
        final session = Uri.tryParse(uri)?.queryParameters['session'];
        if (session != null && session.isNotEmpty) return session;
      }
    }
    final children = node['children'] ?? [];
    if (children is! List || children.length > 32768 - visited) _limit();
    queue.addAll(children.map(_object));
  }
  return null;
}

Never _forbiddenProvider() => throw AssetLoadException(
  AssetLoadError.forbiddenReference,
  'Provider resources must stay on their issued origin.',
);

final class _ProviderPolicy extends SourcePolicy {
  final SourcePolicy caller;
  const _ProviderPolicy(this.caller);
  @override
  void validate(Uri from, Uri to, {String? fieldPath}) {
    if (!_sameOrigin(from, to)) _forbiddenProvider();
    caller.validate(from, to, fieldPath: fieldPath);
  }
}

final class _ProviderCancellation implements LoadCancellation {
  final _callbacks = <void Function()>[];
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
    return Registration(() => _callbacks.remove(callback));
  }

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    for (final callback in [..._callbacks]) {
      callback();
    }
    _callbacks.clear();
  }
}

final class _JoinedProviderCancellation implements LoadCancellation {
  final LoadCancellation caller, owner;
  const _JoinedProviderCancellation(this.caller, this.owner);
  @override
  bool get isCancelled => caller.isCancelled || owner.isCancelled;
  @override
  void throwIfCancelled() {
    caller.throwIfCancelled();
    owner.throwIfCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    var called = false;
    void once() {
      if (!called) {
        called = true;
        callback();
      }
    }

    final a = caller.onCancel(once), b = owner.onCancel(once);
    return Registration(() {
      a.dispose();
      b.dispose();
    });
  }
}
