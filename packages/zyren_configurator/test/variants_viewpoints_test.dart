import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_configurator/zyren_configurator.dart';
import 'package:zyren_configurator/material_variants.dart';
import 'package:zyren_configurator/viewpoints.dart';

Map<String, Object?> fixture({bool duplicate = false}) => {
  'extensions': {
    'KHR_materials_variants': {
      'variants': [
        {'name': 'Red'},
        {'name': 'Base'},
      ],
    },
  },
  'materials': [{}],
  'meshes': [
    {
      'primitives': [
        {
          'extensions': {
            'KHR_materials_variants': {
              'mappings': [
                {
                  'material': 0,
                  'variants': duplicate ? [0, 0] : [0],
                },
              ],
            },
          },
        },
      ],
    },
  ],
};
void main() {
  test(
    'imported variants bind every instance, restore defaults and reload',
    () {
      final imported = ImportedMaterialVariants.fromGltf(
        document: fixture(),
        targets: {
          (0, 0): ['a', 'b'],
        },
        materialIds: {0: 'red'},
      );
      final catalog = ConfigurationCatalog(
        id: 'asset:revision-1',
        revision: 1,
        slots: [imported.slot],
      );
      String? saved;
      for (var reload = 0; reload < 2; reload++) {
        final a = Mesh(BoxGeometry(), UnlitMaterial()),
            b = Mesh(BoxGeometry(), UnlitMaterial());
        final baseline = a.material,
            red = UnlitMaterial(color: const Color3(1, 0, 0));
        final controller = SceneConfigurator(
          catalog: catalog,
          targets: {'a': a, 'b': b},
          materials: {'red': red},
        );
        if (saved == null) {
          controller.apply(catalog.select({'material-variant': 'variant:0'}));
        } else {
          controller.restore(saved);
        }
        saved = controller.current!.encode();
        expect(a.material, same(red));
        expect(b.material, same(red));
        controller.apply(catalog.select({'material-variant': 'variant:1'}));
        expect(a.material, same(baseline));
        controller.close();
      }
      expect(imported.labels['variant:0'], 'Red');
    },
  );
  test(
    'variant import rejects ambiguity, missing bindings and budget overflow',
    () {
      for (final (doc, targets, limit) in [
        (
          fixture(duplicate: true),
          {
            (0, 0): ['a'],
          },
          10,
        ),
        (fixture(), <(int, int), List<String>>{}, 10),
        (
          fixture(),
          {
            (0, 0): ['a', 'a'],
          },
          10,
        ),
        (
          fixture(),
          {
            (0, 0): ['a', 'b'],
          },
          1,
        ),
      ]) {
        expect(
          () => ImportedMaterialVariants.fromGltf(
            document: doc,
            targets: targets,
            materialIds: {0: 'red'},
            maxMappings: limit,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'camera presets validate before writes and hotspots use world transforms',
    () {
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      final node = Group(), parent = Group()..position = const Vec3(1, 0, 0);
      parent.add(node);
      node.position = const Vec3(-1, 0, 0);
      final preset = ConfigurationCameraPreset(
        id: 'front',
        position: const Vec3(0, 0, 10),
        target: Vec3.zero,
      );
      final views = ConfigurationViewpoints(
        presets: [preset],
        targets: {'body': node},
        hotspots: [
          ConfigurationHotspot(
            id: 'center',
            targetId: 'body',
            label: 'Body',
            presetId: 'front',
          ),
        ],
      );
      final projected = views
          .project(camera, const ViewportMetrics(800, 400))
          .single;
      expect(projected['x'], closeTo(400, 1e-8));
      expect(projected['y'], closeTo(200, 1e-8));
      expect(projected['pixelVisibility'], 'unknown');
      expect(projected['insideFrustum'], true);
      parent.visible = false;
      expect(
        views
            .project(camera, const ViewportMetrics(320, 240))
            .single['insideFrustum'],
        false,
      );
      preset.apply(camera);
      expect(camera.position, const Vec3(0, 0, 10));
      expect(
        () => ConfigurationCameraPreset(
          id: 'bad',
          position: Vec3.zero,
          target: Vec3.zero,
        ),
        throwsArgumentError,
      );
      parent.visible = true;
      node.position = const Vec3(-1, 0, 20);
      expect(
        views.project(camera, const ViewportMetrics(320, 240)).single['x'],
        null,
      );
    },
  );
}
