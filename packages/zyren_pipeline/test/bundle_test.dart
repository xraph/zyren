import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

import '../example/triangle_source.dart';

Future<PipelineBundle> triangle({TriangleSource? source}) {
  source ??= TriangleSource();
  return PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
}

void main() {
  test('deterministic archive preserves bytes and source revisions', () async {
    final source = TriangleSource();
    final a = await triangle(source: source);
    final b = await PipelineBuilder(
      resolver: source,
    ).build(entrySourceId: 'model', sources: source.sources.reversed.toList());
    expect(a.version, b.version);
    expect(a.encode(), b.encode());
    final decoded = PipelineBundle.decode(a.encode());
    expect(decoded.encode(), a.encode());
    for (final resource in decoded.resources) {
      expect(resource.bytes, source.files[resource.source.uri]);
      expect(() => resource.bytes[0] = 0, throwsUnsupportedError);
    }
    expect(decoded.resource('model').source.revision, 'drawing-r1');
    expect(decoded.gltfRequest().version, decoded.version);
    expect(decoded.gltfRequest().uri, TriangleSource.modelUri);
    expect(() => decoded.resource('absent'), throwsArgumentError);
    final root = jsonDecode(utf8.decode(decoded.resource('model').bytes));
    expect(root['nodes'][0]['extras']['sourceId'], 'part:triangle');
  });

  test(
    'external buffer loads offline and template closes without killing instance',
    () async {
      final bundle = await triangle();
      await bundle.validateGltf();
      final scope = bundle.open();
      final model = await scope.load(bundle.gltfRequest()).result;
      final instance = model.instantiate();
      final mesh = instance.children.single.children.single as Mesh;
      expect(mesh.geometry.vertexCount, 3);
      await scope.close();
      expect(model.isReleased, isTrue);
      expect(() => model.instantiate(), throwsStateError);
      expect(mesh.geometry.vertexCount, 3);
    },
  );

  test(
    'changing a dependency or source revision changes bundle version',
    () async {
      final source = TriangleSource();
      final before = await triangle(source: source);
      source.files[TriangleSource.bufferUri]![0] = 42;
      final changed = await triangle(source: source);
      expect(changed.version, isNot(before.version));
      expect(changed.resource('model').digest, before.resource('model').digest);
      final revised = await PipelineBuilder(resolver: source).build(
        entrySourceId: 'model',
        sources: [
          source.sources.first,
          PipelineSource(
            sourceId: 'positions',
            revision: 'mesh-r2',
            uri: TriangleSource.bufferUri,
          ),
        ],
      );
      expect(revised.version, isNot(changed.version));
      expect(
        revised.resource('positions').digest,
        changed.resource('positions').digest,
      );
    },
  );

  test(
    'rejects corruption, unsupported schema and invalid field types',
    () async {
      final bundle = await triangle();
      for (final edit in <void Function(dynamic)>[
        (root) => root['payloads'][0] = base64Encode([1, 2, 3]),
        (root) => root['resources'][0]['revision'] = 'tampered',
        (root) => root['resources'][0]['length'] = -1,
        (root) => root['resources'][0]['uri'] = 'relative/path',
        (root) => root['schemaVersion'] = 2,
        (root) => root['processing'] = 'optimized',
        (root) => root['payloads'].removeLast(),
        (root) => root['resources'][0] = 'wrong type',
        (root) => root['version'] = 'bad digest',
      ]) {
        final root = jsonDecode(utf8.decode(bundle.encode()));
        edit(root);
        expect(
          () => PipelineBundle.decode(
            Uint8List.fromList(utf8.encode(jsonEncode(root))),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'rejects duplicate IDs, duplicate URIs and missing entry before reads',
    () async {
      final source = TriangleSource();
      final builder = PipelineBuilder(resolver: source);
      for (final inputs in [
        [source.sources.first, source.sources.first],
        [
          source.sources.first,
          PipelineSource(
            sourceId: 'alias',
            revision: 'r1',
            uri: TriangleSource.modelUri,
          ),
        ],
        <PipelineSource>[],
      ]) {
        await expectLater(
          builder.build(entrySourceId: 'model', sources: inputs),
          throwsFormatException,
        );
      }
    },
  );

  test('budgets cover build, decode and archive allocation', () async {
    final source = TriangleSource();
    await expectLater(
      PipelineBuilder(
        resolver: source,
        limits: const PipelineLimits(maxSources: 1),
      ).build(entrySourceId: 'model', sources: source.sources),
      throwsFormatException,
    );
    await expectLater(
      PipelineBuilder(
        resolver: source,
        limits: const PipelineLimits(maxTotalBytes: 1),
      ).build(entrySourceId: 'model', sources: source.sources),
      throwsA(isA<AssetLoadException>()),
    );
    final bundle = await triangle();
    expect(
      () => bundle.encode(limits: const PipelineLimits(maxArchiveBytes: 1)),
      throwsFormatException,
    );
    expect(
      () => PipelineBundle.decode(
        bundle.encode(),
        limits: const PipelineLimits(maxSourceBytes: 1),
      ),
      throwsFormatException,
    );
    expect(
      () => PipelineBundle.decode(
        bundle.encode(),
        limits: const PipelineLimits(maxArchiveBytes: 1),
      ),
      throwsFormatException,
    );
    final scope = bundle.open(
      services: const AssetServices(limits: AssetLimits(maxSourceBytes: 1)),
    );
    addTearDown(scope.close);
    await expectLater(
      scope.load(bundle.gltfRequest()).result,
      throwsA(isA<AssetLoadException>()),
    );
  });

  test(
    'missing dependencies and malformed glTF cannot pass validation',
    () async {
      final source = TriangleSource();
      final incomplete = await PipelineBuilder(
        resolver: source,
      ).build(entrySourceId: 'model', sources: [source.sources.first]);
      await expectLater(
        incomplete.validateGltf(),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.sourceUnavailable,
          ),
        ),
      );
      source.files[TriangleSource.modelUri] = Uint8List.fromList(
        utf8.encode('{}'),
      );
      final invalid = await triangle(source: source);
      await expectLater(
        invalid.validateGltf(),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );

  test(
    'redirect keeps relative dependencies anchored to effective URI',
    () async {
      final source = TriangleSource();
      final requested = Uri.parse('memory:///latest/model.gltf');
      final redirected = CallbackResolver((uri, context) async {
        if (uri == requested) {
          return ResolvedSource(
            effectiveUri: TriangleSource.modelUri,
            bytes: source.files[TriangleSource.modelUri]!,
          );
        }
        return source.read(uri, context);
      });
      final bundle = await PipelineBuilder(resolver: redirected).build(
        entrySourceId: 'model',
        sources: [
          PipelineSource(sourceId: 'model', revision: 'r1', uri: requested),
          source.sources.last,
        ],
      );
      final decoded = PipelineBundle.decode(bundle.encode());
      expect(decoded.resource('model').effectiveUri, TriangleSource.modelUri);
      await decoded.validateGltf();
    },
  );

  test('rejects redirects outside policy and resolver overreads', () async {
    final source = TriangleSource();
    final escaped = CallbackResolver(
      (uri, _) async => ResolvedSource(
        effectiveUri: Uri.parse('https://external.invalid/model.gltf'),
        bytes: Uint8List(1),
      ),
    );
    await expectLater(
      PipelineBuilder(
        resolver: escaped,
      ).build(entrySourceId: 'model', sources: [source.sources.first]),
      throwsA(isA<AssetLoadException>()),
    );
    final oversized = CallbackResolver(
      (uri, _) async => ResolvedSource(effectiveUri: uri, bytes: Uint8List(2)),
    );
    await expectLater(
      PipelineBuilder(
        resolver: oversized,
        limits: const PipelineLimits(maxSourceBytes: 1),
      ).build(entrySourceId: 'model', sources: [source.sources.first]),
      throwsFormatException,
    );
  });

  test('cancelled build never returns a bundle after a late read', () async {
    final source = TriangleSource();
    final gate = Completer<void>();
    final started = Completer<void>();
    final token = TestCancellation();
    final resolver = CallbackResolver((uri, _) async {
      started.complete();
      await gate.future;
      return ResolvedSource(effectiveUri: uri, bytes: source.files[uri]!);
    });
    final future = PipelineBuilder(resolver: resolver).build(
      entrySourceId: 'model',
      sources: source.sources,
      cancellation: token,
    );
    final assertion = expectLater(future, throwsA(isA<LoadCancelled>()));
    await started.future;
    token.cancel();
    gate.complete();
    await assertion;
    final bundle = await triangle();
    await expectLater(
      bundle.validateGltf(cancellation: token),
      throwsA(isA<LoadCancelled>()),
    );
  });

  test(
    'bundle preserves real CAD model and version-pinned identity sidecar',
    () async {
      final root = Directory(
        'packages/zyren_engineering/test/fixtures/cad/original',
      );
      final modelBytes = await File('${root.path}/model.glb').readAsBytes();
      final sidecarBytes = await File('${root.path}/review.json').readAsBytes();
      final sidecar = jsonDecode(utf8.decode(sidecarBytes));
      final modelUri = Uri.parse('memory:///cad/model.glb');
      final sidecarUri = modelUri.resolve('review.json');
      final resolver = CallbackResolver(
        (uri, _) async => ResolvedSource(
          effectiveUri: uri,
          bytes: uri == modelUri ? modelBytes : sidecarBytes,
        ),
      );
      final bundle = await PipelineBuilder(resolver: resolver).build(
        entrySourceId: 'cad-model',
        sources: [
          PipelineSource(
            sourceId: 'cad-model',
            revision: sidecar['modelVersion'],
            uri: modelUri,
          ),
          PipelineSource(
            sourceId: 'cad-identities',
            revision: sidecar['modelVersion'],
            uri: sidecarUri,
          ),
        ],
      );
      final restored = PipelineBundle.decode(bundle.encode());
      expect(restored.resource('cad-model').digest, sidecar['modelVersion']);
      expect(restored.resource('cad-model').bytes, modelBytes);
      expect(restored.resource('cad-identities').bytes, sidecarBytes);
      await restored.validateGltf();
    },
  );
}

final class CallbackResolver implements ByteSourceResolver {
  final Future<ResolvedSource> Function(Uri, SourceReadContext) callback;
  CallbackResolver(this.callback);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) =>
      callback(uri, context);
}

final class TestCancellation implements LoadCancellation {
  final callbacks = <void Function()>{};
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
    for (final callback in callbacks.toList()) {
      callback();
    }
    callbacks.clear();
  }
}
