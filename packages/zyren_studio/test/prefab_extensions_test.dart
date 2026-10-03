import 'package:test/test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'extensions_test.dart' show LinksCodec, record;

StudioDocument fixture() => StudioDocument(
  id: 'prefabs',
  title: 'Prefabs',
  nodes: [
    StudioNode(
      id: 'instance',
      label: 'Instance',
      kind: StudioNodeKind.prefab,
      prefabId: 'guard',
      extensionOverrides: {
        'test.links': {'speed': 3},
      },
    ),
  ],
  prefabs: [
    StudioPrefab(
      id: 'guard',
      label: 'Guard',
      version: '1',
      nodes: [StudioNode(id: 'actor', label: 'Actor')],
      extensions: {'test.links': record()},
    ),
  ],
);
void main() {
  test(
    'prefab extensions and instance overrides survive restart and history',
    () {
      final document = fixture();
      final restored = StudioDocument.decode(document.encode());
      expect(restored.encode(), document.encode());
      expect(
        restored.prefabs.single.extensions['test.links']!.data['target'],
        'actor',
      );
      final scene = StudioScene(
        restored,
        extensionRegistry: StudioExtensionRegistry()..register(LinksCodec()),
      );
      final edited = restored.copyWith(
        nodes: [
          restored.nodes.single.copyWith(
            extensionOverrides: {
              'test.links': {'speed': 8},
            },
          ),
        ],
      );
      scene.apply(edited);
      expect(scene.canUndo, isTrue);
      scene.undo();
      expect(scene.document.encode(), restored.encode());
    },
  );
  test(
    'prefab required codecs block activation and validate local references',
    () {
      final document = fixture();
      final registry = StudioExtensionRegistry();
      registry.validateDocument(document);
      expect(
        () => registry.validateDocument(document, requireSupported: true),
        throwsStateError,
      );
      registry.register(LinksCodec());
      registry.validateDocument(document, requireSupported: true);
      final invalid = document.copyWith(
        prefabs: [
          document.prefabs.single.copyWith(
            extensions: {'test.links': record(node: 'missing')},
          ),
        ],
      );
      expect(() => registry.validateDocument(invalid), throwsArgumentError);
    },
  );
  test('instance payload is immutable and constrained to prefab nodes', () {
    final fields = <String, Object?>{'speed': 5};
    final node = fixture().nodes.single.copyWith(
      extensionOverrides: {'test.links': fields},
    );
    fields['speed'] = 99;
    expect(node.extensionOverrides['test.links']!['speed'], 5);
    expect(
      () => node.extensionOverrides['test.links']!['speed'] = 7,
      throwsUnsupportedError,
    );
    expect(
      () => StudioNode(
        id: 'box',
        label: 'Box',
        extensionOverrides: {'test.links': {}},
      ),
      throwsArgumentError,
    );
    expect(node.copyWith(kind: StudioNodeKind.box).extensionOverrides, isEmpty);
    expect(
      () => node.copyWith(extensionOverrides: {'invalid': {}}),
      throwsArgumentError,
    );
  });
}
