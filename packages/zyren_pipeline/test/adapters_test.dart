import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_pipeline/engineering.dart';
import 'package:zyren_pipeline/studio.dart';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'bundle_test.dart' show CallbackResolver;

void main() {
  test(
    'CAD adapter verifies byte pairing and rebinds source identities after reload',
    () async {
      final root = Directory(
        'packages/zyren_engineering/test/fixtures/cad/original',
      );
      final model = await File('${root.path}/model.glb').readAsBytes();
      final sidecar = await File('${root.path}/review.json').readAsBytes();
      final uri = Uri.parse('memory:///cad/model.glb');
      Future<PipelineBundle> build() =>
          PipelineBuilder(
            resolver: CallbackResolver(
              (requested, _) async => ResolvedSource(
                effectiveUri: requested,
                bytes: requested == uri ? model : sidecar,
              ),
            ),
          ).build(
            entrySourceId: 'model',
            sources: [
              PipelineSource(sourceId: 'model', revision: 'r1', uri: uri),
              PipelineSource(
                sourceId: 'sidecar',
                revision: 'r1',
                uri: uri.resolve('review.json'),
              ),
            ],
          );
      final bundle = PipelineBundle.decode((await build()).encode());
      final a = await PipelineEngineeringModel.load(
        bundle: bundle,
        modelSourceId: 'model',
        sidecarSourceId: 'sidecar',
      );
      final b = await PipelineEngineeringModel.load(
        bundle: bundle,
        modelSourceId: 'model',
        sidecarSourceId: 'sidecar',
      );
      expect(a.imported.entries, isNotEmpty);
      expect(
        a.imported.entries.map((e) => e.record.id),
        b.imported.entries.map((e) => e.record.id),
      );
      expect(a.instance, isNot(same(b.instance)));
      expect(a.modelVersion, bundle.resource('model').digest);
      await a.close();
      await b.close();
      model[model.length - 1] ^= 1;
      await expectLater(
        PipelineEngineeringModel.load(
          bundle: await build(),
          modelSourceId: 'model',
          sidecarSourceId: 'sidecar',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'Studio store survives disk reload and rejects a stale writer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pipeline-studio-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var disk = FilePipelineCache(directory: directory);
      String? head;
      PipelineStudioStore store() => PipelineStudioStore(
        documentId: 'scene',
        sourceId: 'studio',
        uri: Uri.parse('pipeline:///scene.json'),
        readBundle: () async => head == null ? null : disk.get(head!),
        compareAndWrite: (expected, next) async {
          if (head != expected) return false;
          if (!await disk.put(next, pin: true)) throw StateError('Cache full');
          head = next.version;
          return true;
        },
      );
      final a = store(), stale = store();
      expect(await a.read(), isNull);
      expect(await stale.read(), isNull);
      final scene = StudioScene(
        StudioDocument(
          id: 'scene',
          title: 'Assembly',
          nodes: [StudioNode(id: 'box', label: 'Part')],
        ),
      );
      scene.objects['box']!.position = const Vec3(2, 3, 4);
      await a.write(scene.capture());
      disk = FilePipelineCache(directory: directory);
      final loaded = StudioScene((await store().read())!);
      expect(loaded.objects['box']!.position, const Vec3(2, 3, 4));
      await expectLater(stale.write(scene.capture()), throwsStateError);
      final foreign = StudioDocument(id: 'other', title: 'Other', nodes: []);
      await expectLater(a.write(foreign), throwsArgumentError);
      expect((await store().read())!.id, 'scene');
    },
  );
}
