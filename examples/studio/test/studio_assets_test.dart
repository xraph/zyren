import 'dart:io';
import 'package:zyren_studio/io.dart';
import 'package:zyren_studio/streaming.dart';
import 'package:zyren_pipeline/studio.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio_example/studio_model_bindings.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
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
      final prefix = Directory.current.path.endsWith('/studio') ? '../../' : '';
      final bytes = await File(
        '${prefix}examples/model_viewer/assets/models/deformation.glb',
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
      final output = ZyrenFileStore(
        File('${temp.path}/export/scene.zyren'),
        resources: assets.packageResources,
      );
      await output.export(doc);
      final fresh = StudioPipelineAssets(Directory('${temp.path}/fresh'));
      final stream = await output.openStream();
      await fresh.importPackage(stream);
      final portable = await stream.readDocument();
      await stream.close();
      expect(portable.assets.single.reference, asset.reference);
      final portableScope = await StudioAssetScope.load(portable, fresh);
      expect(
        StudioScene(portable, assets: portableScope).objects['model']!.children,
        isNotEmpty,
      );
      await portableScope.close();
      late ZyrenSceneStream runtime;
      runtime = await ZyrenSceneStream.open(
        output.file.uri,
        read: ZyrenFileStore.readBytes,
        assets: PipelineStudioAssetResolver(
          PipelineAssetLibrary(
            services: SceneRuntime.defaultAssetServices,
            readBundle: (pin, _) async =>
                PipelineBundle.decode(await runtime.readResource(pin)),
          ),
        ),
      );
      await runtime.loadAll();
      expect(
        runtime.loaded.values.single.objects['model']!.children,
        isNotEmpty,
      );
      await runtime.close();
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
      final bindings = StudioModelBindings(scene, registry)..synchronize();
      addTearDown(bindings.dispose);
      Map modelProvider() => (registry.discover()['providers'] as List)
          .cast<Map>()
          .singleWhere((p) => p['providerId'] == 'zyren.gltf-animation');
      final firstBinding = modelProvider();
      final rig = await registry.call(
        providerId: 'zyren.gltf-animation',
        instanceId: firstBinding['instanceId'] as String,
        tool: 'inspect',
        arguments: {'collection': 'nodes'},
      );
      expect(rig.status, AgentStatus.ok);
      expect(rig.data['total'], greaterThan(0));
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
      bindings.synchronize();
      expect(
        modelProvider()['registrationId'],
        isNot(firstBinding['registrationId']),
      );
      final retired = await registry.call(
        providerId: 'zyren.gltf-animation',
        instanceId: firstBinding['instanceId'] as String,
        tool: 'inspect',
        arguments: {'collection': 'nodes'},
      );
      expect(retired.status, AgentStatus.unavailable);
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
      bindings.synchronize();
      expect(modelProvider(), isNotNull);
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
