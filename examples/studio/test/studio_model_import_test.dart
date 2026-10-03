import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_assets.dart';
import 'package:zyren_studio_example/studio_model_import.dart';

void main() {
  test('external glTF buffers are pinned and survive source removal', () async {
    final temp = await Directory.systemTemp.createTemp('studio-gltf-');
    addTearDown(() => temp.delete(recursive: true));
    final rootPath = Directory.current.path.endsWith('/studio') ? '../../' : '';
    final glb = await File(
      '${rootPath}examples/model_viewer/assets/models/deformation.glb',
    ).readAsBytes();
    final view = ByteData.sublistView(glb),
        jsonLength = ByteData.sublistView(glb).getUint32(12, Endian.little);
    final json = jsonDecode(utf8.decode(glb.sublist(20, 20 + jsonLength)));
    final offset = 20 + jsonLength;
    final data = glb.sublist(
      offset + 8,
      offset + 8 + view.getUint32(offset, Endian.little),
    );
    json['buffers'][0]['uri'] = 'mesh.bin';
    final file = File('${temp.path}/mesh.gltf');
    await file.writeAsString(jsonEncode(json));
    expect(
      await studioModelNeedsFolderAccess(file, StudioCancellation()),
      isTrue,
    );
    final embedded = File('${temp.path}/embedded.glb');
    await embedded.writeAsBytes(glb);
    expect(
      await studioModelNeedsFolderAccess(embedded, StudioCancellation()),
      isFalse,
    );
    final bin = File('${temp.path}/mesh.bin');
    await bin.writeAsBytes(data);
    final assets = StudioPipelineAssets(Directory('${temp.path}/cache'));
    final asset = await assets.importFile(
      file,
      id: 'mesh',
      requestFolderAccess: false,
      cancellation: StudioCancellation(),
    );
    await file.delete();
    await bin.delete();
    final doc = StudioDocument(
      id: 'model',
      title: 'Model',
      assets: [asset],
      nodes: [
        StudioNode(
          id: 'instance',
          label: 'Model',
          kind: StudioNodeKind.asset,
          assetId: asset.id,
        ),
      ],
    );
    final scope = await StudioAssetScope.load(doc, assets);
    expect(
      StudioScene(doc, assets: scope).objects['instance']!.children,
      isNotEmpty,
    );
    await scope.close();
    json['buffers'][0]['uri'] = '../outside.bin';
    await file.writeAsString(jsonEncode(json));
    await expectLater(
      prepareStudioModel(
        file,
        id: 'unsafe',
        cancellation: StudioCancellation(),
      ),
      throwsFormatException,
    );
    expect((await assets.cache.inspect()).length, 1);
  });
  test(
    'FBX and OBJ convert into pinned meshes with original sources retained',
    () async {
      final rootPath = Directory.current.path.endsWith('/studio')
          ? ''
          : 'examples/studio/';
      final file = File('${rootPath}test/fixtures/cube.fbx');
      final temp = await Directory.systemTemp.createTemp('studio-fbx-');
      addTearDown(() => temp.delete(recursive: true));
      final assets = StudioPipelineAssets(temp);
      final asset = await assets.importFile(
        file,
        id: 'fbx',
        requestFolderAccess: false,
        cancellation: StudioCancellation(),
      );
      final bundle = await assets.cache.get(
        asset.reference['bundleVersion'] as String,
      );
      expect(bundle!.processing.name, 'derived');
      expect(bundle.resources.length, 2);
      final document = StudioDocument(
        id: 'fbx',
        title: 'FBX',
        assets: [asset],
        nodes: [
          StudioNode(
            id: 'cube',
            label: 'Cube',
            kind: StudioNodeKind.asset,
            assetId: asset.id,
          ),
        ],
      );
      final scope = await StudioAssetScope.load(document, assets);
      expect(
        StudioScene(document, assets: scope).objects['cube']!.children,
        isNotEmpty,
      );
      await scope.close();
      final obj = File('${temp.path}/triangle.obj');
      await obj.writeAsString(
        'o Triangle\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n',
      );
      final importedObj = await assets.importFile(
        obj,
        id: 'obj',
        requestFolderAccess: false,
        cancellation: StudioCancellation(),
      );
      final objBundle = await assets.cache.get(
        importedObj.reference['bundleVersion'] as String,
      );
      expect(objBundle!.processing.name, 'derived');
      expect(objBundle.resources.length, 2);
      await expectLater(
        prepareStudioModel(
          file,
          id: 'missing',
          cancellation: StudioCancellation(),
          blenderExecutable: '/missing/blender',
        ),
        throwsStateError,
      );
    },
    skip: Platform.environment['RUN_STUDIO_CONVERTER'] != '1',
  );
}
