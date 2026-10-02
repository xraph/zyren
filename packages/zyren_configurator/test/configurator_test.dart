import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_configurator/zyren_configurator.dart';

void main() {
  final red = UnlitMaterial(color: const Color3(1, 0, 0));
  ConfigurationCatalog catalog() => ConfigurationCatalog(
    id: 'product',
    revision: 3,
    slots: [
      ConfigurationSlot(
        id: 'finish',
        options: [
          ConfigurationOption(id: 'red', materials: {'body': 'red'}),
          ConfigurationOption(id: 'base'),
        ],
      ),
      ConfigurationSlot(
        id: 'component',
        required: false,
        options: [
          ConfigurationOption(
            id: 'hidden',
            visibility: {'part': false},
            requires: {'finish': 'red'},
          ),
          ConfigurationOption(
            id: 'shown',
            visibility: {'part': true},
            excludes: {'finish': 'red'},
          ),
        ],
      ),
    ],
  );
  SceneConfigurator bind(
    ConfigurationCatalog catalog,
    Mesh mesh,
    Object3D part,
  ) => SceneConfigurator(
    catalog: catalog,
    targets: {'body': mesh, 'part': part},
    materials: {'red': red},
  );

  test(
    'saved choices survive different object identities and restore baseline',
    () {
      final cat = catalog();
      final body = Mesh(BoxGeometry(), UnlitMaterial()), part = Group();
      final first = bind(cat, body, part);
      first.apply(cat.select({'finish': 'red', 'component': 'hidden'}));
      expect(body.material, same(red));
      expect(part.visible, isFalse);
      final encoded = first.current!.encode();
      final nextBody = Mesh(BoxGeometry(), UnlitMaterial()), nextPart = Group();
      final original = nextBody.material;
      expect(nextBody.id, isNot(body.id));
      final next = bind(cat, nextBody, nextPart)..restore(encoded);
      expect(nextBody.material, same(red));
      expect(nextPart.visible, isFalse);
      next.apply(cat.select({'finish': 'base'}));
      expect(nextBody.material, same(original));
      expect(nextPart.visible, isTrue);
      next.close();
      next.close();
      expect(() => next.restore(encoded), throwsStateError);
      first.close();
    },
  );

  test(
    'invalid selections leave previously applied scene and selection intact',
    () {
      final cat = catalog(),
          mesh = Mesh(BoxGeometry(), UnlitMaterial()),
          part = Group();
      final controller = bind(cat, mesh, part);
      final saved = cat.select({'finish': 'red', 'component': 'hidden'});
      controller.apply(saved);
      for (final choices in [
        <String, String>{},
        {'finish': 'missing'},
        {'finish': 'base', 'component': 'hidden'},
        {'finish': 'red', 'component': 'shown'},
        {'finish': 'red', 'unknown': 'x'},
      ]) {
        expect(
          () => controller.apply(SavedConfiguration('product', 3, choices)),
          throwsArgumentError,
        );
        expect(mesh.material, same(red));
        expect(part.visible, isFalse);
        expect(controller.current, same(saved));
      }
      controller.close();
    },
  );

  test('catalog revision and schema mismatches fail explicitly', () {
    final cat = catalog();
    expect(
      () => cat.validate(SavedConfiguration('product', 2, {'finish': 'red'})),
      throwsArgumentError,
    );
    expect(
      () => SavedConfiguration.decode('{"schemaVersion":2}'),
      throwsFormatException,
    );
    expect(
      () => SavedConfiguration.decode(
        '{"schemaVersion":1,"catalogId":"product","catalogRevision":3,"choices":{"finish":5}}',
      ),
      throwsFormatException,
    );
    expect(
      cat.select({'component': 'hidden', 'finish': 'red'}).encode(),
      cat.select({'finish': 'red', 'component': 'hidden'}).encode(),
    );
  });

  test('catalog rejects duplicate IDs and dangling compatibility rules', () {
    expect(
      () => ConfigurationSlot(
        id: 'a',
        options: [
          ConfigurationOption(id: 'x'),
          ConfigurationOption(id: 'x'),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => ConfigurationCatalog(
        id: 'a',
        revision: 1,
        slots: [
          ConfigurationSlot(
            id: 'a',
            options: [
              ConfigurationOption(id: 'x', requires: {'missing': 'value'}),
            ],
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('conflicting writes cannot depend on iteration order', () {
    final cat = ConfigurationCatalog(
      id: 'a',
      revision: 1,
      slots: [
        for (final id in ['a', 'b'])
          ConfigurationSlot(
            id: id,
            options: [
              ConfigurationOption(id: 'x', visibility: {'same': true}),
            ],
          ),
      ],
    );
    expect(() => cat.select({'a': 'x', 'b': 'x'}), throwsArgumentError);
  });

  test(
    'bindings require real unique nodes and topology-compatible materials',
    () {
      final cat = catalog(), mesh = Mesh(BoxGeometry(), UnlitMaterial());
      expect(
        () => SceneConfigurator(
          catalog: cat,
          targets: {'body': mesh},
          materials: {'red': red},
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneConfigurator(
          catalog: cat,
          targets: {'body': mesh, 'part': mesh},
          materials: {'red': red},
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneConfigurator(
          catalog: cat,
          targets: {'body': mesh, 'part': Group()},
          materials: {},
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneConfigurator(
          catalog: cat,
          targets: {'body': mesh, 'part': Group()},
          materials: {'red': LineMaterial()},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'close restores original visibility including initially hidden nodes',
    () {
      final cat = catalog(),
          mesh = Mesh(BoxGeometry(), UnlitMaterial()),
          part = Group()..visible = false;
      final controller = bind(cat, mesh, part);
      controller.apply(cat.select({'finish': 'base', 'component': 'shown'}));
      expect(part.visible, isTrue);
      controller.close();
      expect(part.visible, isFalse);
    },
  );
}
