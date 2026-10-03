import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_assets.dart';

void main() {
  test(
    'native host imports a real GLB pin, reconstructs it and retains root identity on reimport',
    () async {
      final temp = await Directory.systemTemp.createTemp('studio-assets-');
      addTearDown(() => temp.delete(recursive: true));
      final assets = StudioPipelineAssets(temp);
      final bytes = await File(
        'examples/model_viewer/assets/models/deformation.glb',
      ).readAsBytes();
      final asset = await assets.importBytes(
        bytes,
        'deformation.glb',
        id: 'assembly',
        cancellation: StudioCancellation(),
      );
      expect((await assets.inspect(asset)).name, 'available');
      final doc = StudioDocument(
        id: 'imported',
        title: 'Imported',
        assets: [asset],
        nodes: [
          StudioNode(
            id: 'model',
            label: 'Model',
            kind: StudioNodeKind.asset,
            assetId: asset.id,
          ),
        ],
      );
      final scope = await StudioAssetScope.load(doc, assets);
      addTearDown(scope.close);
      final scene = StudioScene(doc, assets: scope);
      expect(scene.objects['model']!.children, isNotEmpty);
      final saved = scene.capture();
      final reloaded = StudioScene(
        StudioDocument.decode(saved.encode()),
        assets: scope,
      );
      expect(reloaded.objects['model']!.children, isNotEmpty);
      final updated = await assets.importBytes(
        bytes,
        'deformation.glb',
        id: asset.id,
        replacing: asset,
        cancellation: StudioCancellation(),
      );
      final next = saved.copyWith(assets: [updated]);
      await scope.prepare(next, assets);
      scene.apply(next);
      expect(scene.objects.keys, ['model']);
      expect(scene.undo(), isTrue);
      expect(scene.capture().assets.single.reference, asset.reference);
      expect(scene.redo(), isTrue);
      expect(scene.capture().assets.single.reference, updated.reference);
      expect(scope.templateCount, 2);
      scene.history.clear();
      await scope.retain([scene.capture()]);
      expect(scope.templateCount, 1);
    },
  );
}
