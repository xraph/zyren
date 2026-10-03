import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../example/triangle_source.dart';

void main() {
  Future<PipelineBundle> bundle({double width = 1}) {
    final source = TriangleSource(width: width);
    return PipelineBuilder(
      resolver: source,
    ).build(entrySourceId: 'model', sources: source.sources);
  }

  test(
    'saved asset references retain source pins and offline scoped lifetime',
    () async {
      final original = await bundle();
      final reference = PipelineAssetReference.decode(
        PipelineAssetReference.fromBundle(original).encode(),
      );
      final cache = PipelineCache()..put(original);
      final library = PipelineAssetLibrary(
        readBundle: (version, _) async => cache.get(version),
      );
      expect(reference.sourceRevision, 'drawing-r1');
      expect(reference.uri, TriangleSource.modelUri);
      expect(await library.inspect(reference), PipelineAssetStatus.available);
      final loaded = await library.loadGltf(reference);
      final instance = loaded.instantiate();
      cache.invalidateSource('model');
      expect(
        await library.inspect(reference),
        PipelineAssetStatus.missingBundle,
      );
      expect(instance.children, isNotEmpty);
      await loaded.close();
      expect(loaded.model.isReleased, isTrue);
      expect(() => loaded.instantiate(), throwsStateError);
      expect(instance.children, isNotEmpty);
    },
  );
  test(
    'missing, changed and denied inputs stay distinct and never fall back',
    () async {
      final original = await bundle(), changed = await bundle(width: 2);
      final reference = PipelineAssetReference.fromBundle(original);
      final wrong = PipelineAssetLibrary(readBundle: (_, _) async => changed);
      expect(await wrong.inspect(reference), PipelineAssetStatus.mismatch);
      await expectLater(
        wrong.loadGltf(reference),
        throwsA(isA<PipelineAssetUnavailable>()),
      );
      final library = PipelineAssetLibrary(
        readBundle: (_, _) async => original,
      );
      PipelineAssetReference altered(String field, Object value) =>
          PipelineAssetReference.fromJson({
            ...reference.toJson(),
            field: value,
          });
      expect(
        await library.inspect(altered('sourceId', 'gone')),
        PipelineAssetStatus.missingSource,
      );
      expect(
        await library.inspect(altered('sourceRevision', 'later')),
        PipelineAssetStatus.mismatch,
      );
      expect(
        await library.inspect(
          altered('uri', 'https://elsewhere.invalid/model.glb'),
        ),
        PipelineAssetStatus.mismatch,
      );
      final denied = PipelineAssetLibrary(
        readBundle: (_, _) async => throw StateError('Denied by host'),
      );
      await expectLater(denied.inspect(reference), throwsStateError);
    },
  );
  test(
    'reference validation is bounded and rejects ambiguous schemas',
    () async {
      final reference = PipelineAssetReference.fromBundle(await bundle());
      for (final value in [
        {...reference.toJson(), 'schemaVersion': 2},
        {...reference.toJson(), 'sha256': 'bad'},
        {...reference.toJson(), 'sourceId': 42},
        {...reference.toJson(), 'extra': true},
        {...reference.toJson(), 'uri': 'relative'},
      ]) {
        expect(
          () => PipelineAssetReference.decode(jsonEncode(value)),
          throwsFormatException,
        );
      }
      expect(
        () => PipelineAssetReference.decode(' ' * 16385),
        throwsFormatException,
      );
    },
  );
  test(
    'late store completion after cancellation cannot create a template',
    () async {
      final original = await bundle();
      final gate = Completer<PipelineBundle?>();
      final library = PipelineAssetLibrary(readBundle: (_, _) => gate.future);
      final token = PipelineCancellation();
      final future = library.loadGltf(
        PipelineAssetReference.fromBundle(original),
        cancellation: token,
      );
      final check = expectLater(future, throwsA(isA<LoadCancelled>()));
      token.cancel();
      gate.complete(original);
      await check;
    },
  );
}
