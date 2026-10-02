import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';

const googleRoot = 'https://tile.googleapis.com/v1/3dtiles/root.json';
const ionEndpoint = 'https://api.cesium.com/v1/assets/2275207/endpoint';
ResolvedSource jsonResponse(Uri uri, Object data) => ResolvedSource(
  effectiveUri: uri,
  bytes: Uint8List.fromList(utf8.encode(jsonEncode(data))),
  headers: {'cache-control': 'private, max-age=30'},
);
ResolvedSource googleManifest(Uri uri, String session) => ResolvedSource(
  effectiveUri: uri,
  bytes: tilesetBytes(
    tile(refine: 'REPLACE', uri: 'next.json?session=$session'),
  ),
  headers: {'cache-control': 'private, max-age=30'},
);

class Transport implements ByteSourceResolver {
  final Future<ResolvedSource> Function(Uri, SourceReadContext) handler;
  final calls = <(Uri, Map<String, String>)>[];
  Transport(this.handler);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    calls.add((uri, context.headers));
    context.cancellation.throwIfCancelled();
    final result = await handler(uri, context);
    context.reportProgress(result.bytes.length, result.bytes.length);
    return result;
  }
}

class Signal implements LoadCancellation {
  final callbacks = <void Function()>[];
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
      callbacks.add(callback);
    }
    return Registration(() => callbacks.remove(callback));
  }

  void cancel() {
    isCancelled = true;
    for (final callback in [...callbacks]) {
      callback();
    }
    callbacks.clear();
  }
}

SourceReadContext readContext({
  Signal? signal,
  SourcePolicy policy = const SourcePolicy(),
}) => SourceReadContext(
  maxBytes: 65536,
  cancellation: signal ?? Signal(),
  policy: policy,
  onProgress: (_, _) {},
);

class AnyOrigin extends SourcePolicy {
  const AnyOrigin();
  @override
  void validate(Uri from, Uri to, {String? fieldPath}) {}
}

void main() {
  test(
    'Google key and session stay private while a scoped loader uses sanitized source URLs',
    () async {
      final transport = Transport((uri, context) async {
        expect(uri.host, 'tile.googleapis.com');
        expect(uri.queryParameters['key'], 'google-fixture-key');
        return googleManifest(uri, 'session-one');
      });
      final provider = await Tiles3DProvider.googleMaps(
        transport: transport,
        apiKey: () => 'google-fixture-key',
      );
      addTearDown(provider.close);
      expect(provider.rootUri.toString(), googleRoot);
      final assets = AssetScope(services: AssetServices(resolver: provider));
      addTearDown(assets.close);
      final tileset = await assets
          .load(Tiles3D.tileset(provider.rootUri))
          .result;
      expect(transport.calls, hasLength(1));
      expect(tileset.sourceUri.queryParameters, isEmpty);
      final source = await provider.read(
        tileset.root.contentUri!,
        readContext(),
      );
      expect(transport.calls.last.$1.queryParameters['session'], 'session-one');
      expect(source.effectiveUri.queryParameters.keys, isNot(contains('key')));
      expect(source.headers['cache-control'], 'private, max-age=30');
      await expectLater(
        provider.read(
          Uri.parse('https://other.test/asset'),
          readContext(policy: const AnyOrigin()),
        ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.forbiddenReference,
          ),
        ),
      );
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'Google root reload omits the old session and renews dependent requests',
    () async {
      var roots = 0;
      final transport = Transport((uri, _) async {
        if (uri.path.endsWith('root.json')) {
          if (uri.queryParameters.containsKey('session')) {
            throw AssetLoadException(
              AssetLoadError.sourceFailed,
              'root session rejected',
              httpStatus: 400,
            );
          }
          return googleManifest(uri, 's${++roots}');
        }
        expect(uri.queryParameters['session'], 's2');
        return ResolvedSource(effectiveUri: uri, bytes: Uint8List(1));
      });
      final provider = await Tiles3DProvider.googleMaps(
        transport: transport,
        apiKey: () => 'fixture-key',
      );
      addTearDown(provider.close);
      await provider.read(provider.rootUri, readContext());
      await provider.read(provider.rootUri, readContext());
      await provider.read(provider.rootUri.resolve('child'), readContext());
      expect(roots, 2);
    },
  );

  test(
    '3DTILES_content_gltf declaration admits ordinary glTF content manifests',
    () async {
      final data = {
        'asset': {'version': '1.0'},
        'extensionsUsed': ['3DTILES_content_gltf'],
        'extensionsRequired': ['3DTILES_content_gltf'],
        'geometricError': 1000,
        'root': tile(refine: 'REPLACE', uri: 'child.glb'),
      };
      final assets = AssetScope(
        services: AssetServices(
          resolver: Transport((uri, _) async => jsonResponse(uri, data)),
        ),
      );
      addTearDown(assets.close);
      final tileset = await assets
          .load(Tiles3D.tileset(Uri.parse(googleRoot)))
          .result;
      expect(tileset.root.contentUri!.path, '/v1/3dtiles/child.glb');
    },
  );

  test(
    'Ion endpoint token is exchanged for Google credentials and preserves credits',
    () async {
      final transport = Transport((uri, context) async {
        if (uri.host == 'api.cesium.com') {
          expect(uri.toString().split('?').first, ionEndpoint);
          expect(uri.queryParameters['access_token'], 'ion-fixture-token');
          expect(context.headers, isEmpty);
          return jsonResponse(uri, {
            'type': '3DTILES',
            'externalType': '3DTILES',
            'options': {'url': '$googleRoot?key=issued-google-key'},
            'attributions': [
              {
                'html': '<a href="https://cesium.com/">Cesium</a>',
                'collapsible': false,
              },
            ],
          });
        }
        expect(uri.host, 'tile.googleapis.com');
        expect(uri.queryParameters['key'], 'issued-google-key');
        expect(
          uri.queryParameters.values,
          isNot(contains('ion-fixture-token')),
        );
        expect(context.headers, isEmpty);
        return googleManifest(uri, 'issued-session');
      });
      final provider = await Tiles3DProvider.cesiumIon(
        transport: transport,
        accessToken: () => 'ion-fixture-token',
        assetId: 2275207,
      );
      addTearDown(provider.close);
      expect(provider.rootUri.toString(), googleRoot);
      expect(provider.attributions.single.html, contains('Cesium'));
      expect(provider.attributions.single.collapsible, isFalse);
      expect(provider.isGoogleMaps, isTrue);
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'Ion hosted assets use a bearer token only at the issued origin',
    () async {
      final transport = Transport((uri, context) async {
        if (uri.host == 'api.cesium.com') {
          return jsonResponse(uri, {
            'type': '3DTILES',
            'url': 'https://assets.cesium.com/12/tileset.json?v=4',
            'accessToken': 'issued-bearer',
            'attributions': [],
          });
        }
        expect(uri.host, 'assets.cesium.com');
        expect(context.headers['Authorization'], 'Bearer issued-bearer');
        expect(uri.queryParameters['v'], '4');
        return ResolvedSource(
          effectiveUri: uri,
          bytes: tilesetBytes(tile(refine: 'REPLACE', uri: 'child.glb')),
        );
      });
      final provider = await Tiles3DProvider.cesiumIon(
        transport: transport,
        accessToken: () => 'ion-fixture-token',
        assetId: 12,
      );
      addTearDown(provider.close);
      final source = await provider.read(provider.rootUri, readContext());
      expect(
        source.effectiveUri.toString(),
        'https://assets.cesium.com/12/tileset.json?v=4',
      );
      expect(provider.isGoogleMaps, isFalse);
      await expectLater(
        provider.read(
          Uri.parse('https://attacker.test/file'),
          readContext(policy: const AnyOrigin()),
        ),
        throwsA(isA<AssetLoadException>()),
      );
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'concurrent expired Google sessions share one refresh and retry once',
    () async {
      var roots = 0;
      final gate = Completer<void>();
      final transport = Transport((uri, context) async {
        if (uri.path.endsWith('/root.json')) {
          roots++;
          if (roots == 2) await gate.future;
          return googleManifest(uri, 'session-$roots');
        }
        if (uri.queryParameters['session'] == 'session-1') {
          throw AssetLoadException(
            AssetLoadError.sourceFailed,
            'fixture rejected',
            httpStatus: 403,
          );
        }
        expect(uri.queryParameters['session'], 'session-2');
        return ResolvedSource(
          effectiveUri: uri,
          bytes: Uint8List.fromList([1]),
        );
      });
      final provider = await Tiles3DProvider.googleMaps(
        transport: transport,
        apiKey: () => 'fixture-key',
      );
      addTearDown(provider.close);
      final one = provider.read(
        Uri.parse('https://tile.googleapis.com/a?session=old'),
        readContext(),
      );
      final two = provider.read(
        Uri.parse('https://tile.googleapis.com/b?session=old'),
        readContext(),
      );
      for (var i = 0; i < 100 && roots < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(roots, 2);
      gate.complete();
      expect(await Future.wait([one, two]), hasLength(2));
      expect(roots, 2);
      expect(transport.calls, hasLength(6));
    },
  );

  test(
    'persistent denial retries once and cannot start a refresh loop',
    () async {
      var roots = 0, content = 0;
      final transport = Transport((uri, _) async {
        if (uri.path.endsWith('root.json')) {
          return googleManifest(uri, 's${++roots}');
        }
        content++;
        throw AssetLoadException(
          AssetLoadError.sourceFailed,
          'denied',
          httpStatus: 401,
        );
      });
      final provider = await Tiles3DProvider.googleMaps(
        transport: transport,
        apiKey: () => 'fixture-key',
      );
      addTearDown(provider.close);
      await expectLater(
        provider.read(provider.rootUri.resolve('child'), readContext()),
        throwsA(
          isA<AssetLoadException>().having((e) => e.httpStatus, 'status', 401),
        ),
      );
      expect(roots, 2);
      expect(content, 2);
    },
  );

  test(
    'external Ion endpoint cannot send a Google key to an unrelated origin',
    () async {
      final transport = Transport(
        (uri, _) async => jsonResponse(uri, {
          'type': '3DTILES',
          'externalType': '3DTILES',
          'options': {'url': 'https://unrelated.test/root?key=issued-key'},
        }),
      );
      await expectLater(
        Tiles3DProvider.cesiumIon(
          transport: transport,
          accessToken: () => 'ion-fixture',
          assetId: 2275207,
        ),
        throwsA(isA<AssetLoadException>()),
      );
      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.$1.host, 'api.cesium.com');
    },
  );

  test(
    'credential errors expose status without the secret URI or cause',
    () async {
      final transport = Transport(
        (uri, _) async => throw AssetLoadException(
          AssetLoadError.sourceFailed,
          'secret=${uri.queryParameters['key']}',
          httpStatus: 403,
          sourceUri: uri,
          cause: StateError(uri.toString()),
        ),
      );
      await expectLater(
        Tiles3DProvider.googleMaps(
          transport: transport,
          apiKey: () => 'do-not-print',
        ),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.httpStatus, 'status', 403)
              .having(
                (e) => '${e.issue}',
                'message',
                isNot(contains('do-not-print')),
              )
              .having((e) => e.issue.cause, 'cause', isNull),
        ),
      );
    },
  );

  test(
    'provider disposal waits for an uncooperative physical read and rejects late results',
    () async {
      final gate = Completer<void>(), started = Completer<void>();
      final transport = Transport((uri, _) async {
        if (uri.path.endsWith('root.json')) return googleManifest(uri, 's1');
        started.complete();
        await gate.future;
        return ResolvedSource(
          effectiveUri: uri,
          bytes: Uint8List.fromList([1]),
        );
      });
      final provider = await Tiles3DProvider.googleMaps(
        transport: transport,
        apiKey: () => 'fixture-key',
      );
      final result = provider.read(
        Uri.parse('https://tile.googleapis.com/child'),
        readContext(),
      );
      final cancelled = expectLater(result, throwsA(isA<LoadCancelled>()));
      await started.future;
      var closed = false;
      final closing = provider.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closed, isFalse);
      gate.complete();
      await closing;
      await cancelled;
      expect(closed, isTrue);
    },
  );
}
