import 'dart:convert';
import 'dart:async';
import 'authoring_test.dart' show prefabDocument;
import 'prefab_extensions_test.dart' as extended;
import 'extensions_test.dart' show LinksCodec;
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/streaming.dart';
import 'package:zyren_studio/io.dart';

void main() {
  StudioDocument fixture() => StudioDocument(
    id: 'stream',
    title: 'Stream',
    environment: StudioEnvironment(
      background: 0x192938,
      keyIntensity: 2,
      fillIntensity: .4,
    ),
    nodes: [
      StudioNode(
        id: 'a',
        label: 'A',
        rotation: Quat.axisAngle(const Vec3(0, 1, 0), .4),
        material: StudioMaterial(
          kind: StudioMaterialKind.standard,
          metallic: .6,
          roughness: .3,
        ),
      ),
      StudioNode(id: 'b', label: 'B', position: const Vec3(3, 0, 0)),
    ],
  );
  test(
    'compiled chunks load independently, preserve appearance and retire safely',
    () async {
      final source = fixture(), package = ZyrenScenePackage.compile(fixture());
      final requests = <String>[];
      Future<Uint8List> read(Uri uri, int max, LoadCancellation cancel) async {
        cancel.throwIfCancelled();
        requests.add(uri.path);
        return uri.path.endsWith('.zyren')
            ? package.manifest
            : package.files[uri.path.substring(1)]!;
      }

      final stream = await ZyrenSceneStream.open(
        Uri.parse('asset:/scene.zyren'),
        read: read,
      );
      expect(requests, ['/scene.zyren']);
      expect(stream.loaded, isEmpty);
      final first = await stream.loadChunk('a');
      expect(stream.loaded.keys, ['a']);
      expect(requests.length, 2);
      expect(
        first.capture().nodes.single.toJson(),
        source.nodes.first.toJson(),
      );
      expect(
        stream.scene.background,
        Color3.hex(source.environment.background),
      );
      expect(stream.scene.children, contains(first.scene));
      expect(identical(first, await stream.loadChunk('a')), isTrue);
      await stream.loadAll();
      final restored = await stream.readDocument();
      expect(restored.encode(), source.encode());
      await stream.unloadChunk('a');
      expect(first.scene.parent, isNull);
      await stream.close();
      expect(stream.loaded, isEmpty);
      expect(() => stream.loadChunk('b'), throwsStateError);
    },
  );
  test(
    'corrupt chunks and traversal references fail before attachment',
    () async {
      final package = ZyrenScenePackage.compile(fixture());
      Future<Uint8List> read(Uri uri, int max, LoadCancellation cancel) async =>
          uri.path.endsWith('.zyren')
          ? package.manifest
          : Uint8List.fromList([1, 2]);
      final stream = await ZyrenSceneStream.open(
        Uri.parse('asset:/scene.zyren'),
        read: read,
      );
      await expectLater(stream.loadChunk('a'), throwsFormatException);
      expect(stream.loaded, isEmpty);
      await stream.close();
      final root = jsonDecode(utf8.decode(package.manifest));
      root['chunks'][0]['uri'] = '../outside';
      await expectLater(
        ZyrenSceneStream.open(
          Uri.parse('asset:/scene.zyren'),
          read: (_, _, _) async =>
              Uint8List.fromList(utf8.encode(jsonEncode(root))),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'prefab export preserves stable animation targets and required plugin data',
    () async {
      for (final document in [prefabDocument(), extended.fixture()]) {
        final package = ZyrenScenePackage.compile(document);
        Future<Uint8List> read(
          Uri uri,
          int max,
          LoadCancellation cancel,
        ) async => uri.path.endsWith('.zyren')
            ? package.manifest
            : package.files[uri.path.substring(1)]!;
        final stream = await ZyrenSceneStream.open(
          Uri.parse('asset:/scene.zyren'),
          read: read,
          extensions: StudioExtensionRegistry()..register(LinksCodec()),
        );
        expect(stream.chunkIds, hasLength(1));
        await stream.loadAll();
        final restored = await stream.readDocument();
        expect(restored.expandedNodes.keys, document.expandedNodes.keys);
        expect(
          restored.clips.map((c) => c.toJson()),
          document.clips.map((c) => c.toJson()),
        );
        expect(
          restored.prefabs
              .where((p) => p.extensions.isNotEmpty)
              .map((p) => p.toJson()),
          document.prefabs
              .where((p) => p.extensions.isNotEmpty)
              .map((p) => p.toJson()),
        );
        await stream.close();
      }
    },
  );
  test('plugin prefab manifests retain referenced asset definitions', () async {
    final source = extended.fixture().copyWith(
      assets: [
        StudioAsset(
          id: 'model',
          label: 'Model',
          provider: 'test.asset',
          reference: {'pin': '1'},
        ),
      ],
      prefabs: [
        extended.fixture().prefabs.single.copyWith(
          nodes: [
            StudioNode(
              id: 'actor',
              label: 'Actor',
              kind: StudioNodeKind.asset,
              assetId: 'model',
            ),
          ],
        ),
      ],
    );
    final package = ZyrenScenePackage.compile(source);
    final stream = await ZyrenSceneStream.open(
      Uri.parse('asset:/scene.zyren'),
      read: (uri, _, _) async => uri.path.endsWith('.zyren')
          ? package.manifest
          : package.files[uri.path.substring(1)]!,
    );
    expect((await stream.readDocument()).encode(), source.encode());
    await expectLater(stream.loadAll(), throwsStateError);
    expect(stream.loaded, isEmpty);
    await stream.close();
  });
  test(
    'closing during transport cancels and prevents late attachment',
    () async {
      final package = ZyrenScenePackage.compile(fixture());
      final requested = Completer<void>(), release = Completer<void>();
      final stream = await ZyrenSceneStream.open(
        Uri.parse('asset:/scene.zyren'),
        read: (uri, max, cancel) async {
          if (uri.path.endsWith('.zyren')) return package.manifest;
          requested.complete();
          await release.future;
          return package.files[uri.path.substring(1)]!;
        },
      );
      final loading = stream.loadChunk('a');
      final failure = expectLater(loading, throwsA(isA<Exception>()));
      await requested.future;
      final closing = stream.close();
      release.complete();
      await failure;
      await closing;
      expect(stream.loaded, isEmpty);
    },
  );
  test(
    'file save and runtime export reopen with identical authored state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-scene-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = fixture(),
          store = ZyrenFileStore(File('${directory.path}/scene.zyren'));
      await store.write(source);
      expect((await store.read())!.encode(), source.encode());
      final output = ZyrenFileStore(File('${directory.path}/runtime.zyren'));
      await output.export(source);
      expect((await output.read())!.encode(), source.encode());
      final loaded = StudioScene(source);
      final before = loaded.capture();
      loaded.apply(
        before.copyWith(environment: StudioEnvironment(background: 0x111111)),
      );
      expect(loaded.scene.background, Color3.hex(0x111111));
      expect(loaded.undo(), isTrue);
      expect(
        loaded.scene.background,
        Color3.hex(source.environment.background),
      );
    },
  );
}
