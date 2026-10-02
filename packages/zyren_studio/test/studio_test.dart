import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/io.dart';
import '../../zyren/test/support/fakes.dart';

StudioDocument fixture() => StudioDocument(
  id: 'study',
  title: 'Study',
  nodes: [
    StudioNode(
      id: 'box',
      label: 'Part',
      parentId: 'assembly',
      sourceId: 'cad:part',
      position: const Vec3(1, 2, 3),
      scale: const Vec3(2, 1, -1),
      color: 0x102030,
    ),
    StudioNode(id: 'assembly', label: 'Assembly', kind: StudioNodeKind.group),
  ],
  review: EngineeringDocument(
    id: 'study',
    objects: [
      EngineeringObject(
        id: 'cad:part',
        label: 'Part',
        properties: {'tag': 'A-1'},
      ),
    ],
    annotations: [
      EngineeringAnnotation(
        id: 'note',
        objectId: 'cad:part',
        text: 'Check clearance',
        anchor: const Vec3(.2, 0, 0),
      ),
    ],
  ),
);

void main() {
  test(
    'saved scene reconstructs hierarchy, source identity, pose and review',
    () async {
      final document = StudioDocument.decode(fixture().encode());
      final scene = StudioScene(document);
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [scene.tools, scene.engineering],
      );
      addTearDown(engine.dispose);
      scene.bindReview();
      final box = scene.objects['box']!;
      expect(box.parent, same(scene.objects['assembly']));
      expect(scene.engineering.idFor(box), 'cad:part');
      scene.tools.select(box);
      scene.tools.transform(box, position: const Vec3(4, 5, 6));
      expect(scene.tools.undo(), isTrue);
      expect(box.position, const Vec3(1, 2, 3));
      expect(scene.tools.redo(), isTrue);
      scene.scene.add(Group(name: 'Renderer helper'));
      final saved = scene.capture();
      final reloaded = StudioScene(StudioDocument.decode(saved.encode()));
      expect(reloaded.objects['box']!.position, const Vec3(4, 5, 6));
      expect(reloaded.objects['box']!.scale, const Vec3(2, 1, -1));
      expect(
        (reloaded.objects['box'] as Mesh).material.color,
        Color3.hex(0x102030),
      );
      expect(
        reloaded.document.review.annotations['note']!.text,
        'Check clearance',
      );
      expect(saved.nodes.length, 2);
      expect(reloaded.objects['box']!.id, isNot(box.id));
      expect(scene.idFor(box), reloaded.idFor(reloaded.objects['box']));
    },
  );

  test(
    'invalid schema, vectors, references, cycles and source aliases fail',
    () {
      final valid = jsonDecode(fixture().encode()) as Map<String, dynamic>;
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['schemaVersion'] = 9,
        (v) => v['nodes'][0]['position'] = [0, 1],
        (v) => v['nodes'][0]['rotation'] = [0, 0, 0, 0],
        (v) => v['nodes'][0]['scale'] = [1, 0, 1],
        (v) => v['nodes'][0]['kind'] = 'external-mesh',
        (v) => v['nodes'][0]['parentId'] = 'missing',
        (v) => v['nodes'][1]['parentId'] = 'box',
        (v) => v['nodes'][0]['sourceId'] = 'missing',
        (v) => v['nodes'][1]['sourceId'] = 'cad:part',
        (v) => v['nodes'][1]['id'] = 'box',
        (v) => v['camera']['near'] = -1,
        (v) => v['review']['documentId'] = 'different',
      ]) {
        final value = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
        mutate(value);
        expect(
          () => StudioDocument.decode(jsonEncode(value)),
          throwsFormatException,
        );
      }
      expect(() => StudioDocument.decode('null'), throwsFormatException);
      expect(
        () => StudioDocument.decode('x' * (StudioDocument.maxCharacters + 1)),
        throwsFormatException,
      );
    },
  );

  test(
    'unknown objects and external material edits cannot disappear on save',
    () {
      final scene = StudioScene(fixture());
      final extra = scene.content.add(Group());
      expect(scene.capture, throwsStateError);
      scene.content.remove(extra);
      expect(scene.capture().nodes.length, 2);
      (scene.objects['box'] as Mesh).material = UnlitMaterial();
      expect(scene.capture, throwsStateError);
    },
  );

  test(
    'file round trip, missing file and failed replacement retain evidence',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-studio-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/scene.json');
      final store = FileStudioStore(file: file, documentId: 'study');
      expect(await store.read(), isNull);
      await store.write(fixture());
      final saved = await file.readAsString();
      expect((await store.read())!.encode(), saved);
      expect(
        () =>
            store.write(StudioDocument(id: 'other', title: 'Other', nodes: [])),
        throwsFormatException,
      );
      expect(await file.readAsString(), saved);
      await file.writeAsString('{broken');
      await expectLater(store.read(), throwsFormatException);
      await store.write(fixture());
      expect(await file.readAsString(), saved);
      expect(await dir.list().length, 1);
      final targetDirectory = await Directory('${dir.path}/directory').create();
      final failing = FileStudioStore(
        file: File(targetDirectory.path),
        documentId: 'study',
      );
      await expectLater(
        failing.write(fixture()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await targetDirectory.exists(), isTrue);
      expect(await dir.list().length, 2);
    },
  );
}
