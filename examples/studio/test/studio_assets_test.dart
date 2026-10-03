import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio_example/asset_agents.dart';
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
        mapSources: (nodes, _) async => {'part': nodes.keys.first},
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
      final registry = AgentRegistry();
      addTearDown(registry.dispose);
      final provider = StudioAssetsAgentProvider(
        scene: scene,
        assets: assets,
        instanceId: 'assets',
      );
      registry.register(provider);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'status',
        ),
        isEmpty,
      );
      final status = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'status',
      );
      expect((status.data['assets'] as List).single['status'], 'available');
      expect(scene.objects['model']!.children, isNotEmpty);
      scene.engineering.putAnnotation(
        EngineeringAnnotation(
          id: 'note',
          objectId: 'model:part',
          text: 'Keep this source note',
          anchor: Vec3.zero,
        ),
      );
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
        mapSources: (nodes, prior) async => prior,
        cancellation: StudioCancellation(),
      );
      expect(updated.sourceNodes, asset.sourceNodes);
      final pinnedBeforeFailure = (await assets.cache.inspect()).length;
      await expectLater(
        assets.importBytes(
          bytes,
          'deformation.glb',
          id: asset.id,
          replacing: asset,
          mapSources: (_, _) async => {'part': 999999},
          cancellation: StudioCancellation(),
        ),
        throwsStateError,
      );
      expect((await assets.cache.inspect()).length, pinnedBeforeFailure);
      final next = saved.copyWith(assets: [updated]);
      await scope.prepare(next, assets);
      scene.apply(next);
      expect(scene.objects.keys, ['model']);
      expect(
        scene.capture().review.annotations['note']!.objectId,
        'model:part',
      );
      expect(
        scene.capture().review.annotations['note']!.text,
        'Keep this source note',
      );
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
