import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';

void main() {
  Future<Tileset3D> parse(
    Map<String, Object?> root, {
    Tiles3DLimits? limits,
  }) async {
    final scope = AssetScope(
      services: AssetServices(
        resolver: MemoryResolver({'/tileset.json': tilesetBytes(root)}),
      ),
    );
    addTearDown(scope.close);
    return scope
        .load(
          Tiles3D.tileset(
            Uri.parse('https://tiles.test/tileset.json'),
            limits: limits,
          ),
        )
        .result;
  }

  test(
    'arbitrary children inherit refinement and composed ECEF transforms',
    () async {
      final transform = Mat4.compose(
        const Vec3(6378137, 0, 0),
        Quat.identity,
        const Vec3(2, 3, 4),
      );
      final root = tile(
        refine: 'ADD',
        error: 10,
        transform: transform.storage,
        children: [
          for (var i = 0; i < 7; i++)
            tile(
              uri: 'models/$i.glb',
              transform: Mat4.compose(
                const Vec3(1, 0, 0),
                Quat.identity,
                Vec3.one,
              ).storage,
            ),
        ],
      );
      final source = await parse(root);
      expect(source.root.children.length, 7);
      final child = source.root.children.first;
      expect(child.refinement, TileRefinement.add);
      expect(child.transform.storage[12], 6378139);
      expect(source.root.geometricError, 40);
      expect(child.bounds.center.x, 6378139);
      expect(child.bounds.radius, 40);
      expect(child.contentUri.toString(), 'https://tiles.test/models/0.glb');
    },
  );
  test(
    'region bounds ignore tile transform and cover dateline and poles',
    () async {
      final root =
          tile(
              refine: 'REPLACE',
              transform: Mat4.compose(
                const Vec3(1e9, 0, 0),
                Quat.identity,
                Vec3.one,
              ).storage,
            )
            ..['boundingVolume'] = {
              'region': [
                math.pi - .01,
                1.55,
                -math.pi + .01,
                math.pi / 2,
                -50,
                200,
              ],
            };
      final source = await parse(root);
      expect(source.root.bounds.center.length, lessThan(6400000));
      expect(source.root.bounds.radius, greaterThan(100000));
    },
  );
  test('box bounds remain conservative under shear', () async {
    final root =
        tile(
            refine: 'REPLACE',
            transform: [1, 0, 0, 0, 3, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
          )
          ..['boundingVolume'] = {
            'box': [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
          };
    final bounds = (await parse(root)).root.bounds;
    expect(bounds.radius, greaterThanOrEqualTo(math.sqrt(18)));
  });
  test(
    'oriented boxes cull offscreen slabs without their loose spheres',
    () async {
      for (final camera in <Camera>[
        PerspectiveCamera(position: Vec3.zero, target: const Vec3(0, 0, -1)),
        OrthographicCamera(
          position: Vec3.zero,
          target: const Vec3(0, 0, -1),
          left: -10,
          right: 10,
          bottom: -10,
          top: 10,
        ),
      ]) {
        for (final (center, visible) in [
          (const Vec3(1000, 0, -20), false),
          (const Vec3(0, 0, 100), false),
          (const Vec3(0, 0, -20), true),
        ]) {
          final root = tile(refine: 'REPLACE')
            ..['boundingVolume'] = {
              'box': [...center.storage, 1, 0, 0, 0, 10000, 0, 0, 0, 1],
            };
          expect(
            (await parse(
              root,
            )).root.bounds.isVisible(camera, const ViewportMetrics(800, 600)),
            visible,
          );
        }
        for (final (x, visible) in [(30.0, true), (50.0, false)]) {
          final root =
              tile(
                  refine: 'REPLACE',
                  transform: [1, 0, 0, 0, 3, 1, 0, 0, 0, 0, 1, 0, x, 0, -20, 1],
                )
                ..['boundingVolume'] = {
                  'box': [0, 0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 1],
                };
          expect(
            (await parse(
              root,
            )).root.bounds.isVisible(camera, const ViewportMetrics(800, 600)),
            visible,
            reason:
                'Apply shear to every half axis before testing the frustum.',
          );
        }
      }
    },
  );
  test('unsupported traversal features fail explicitly', () async {
    for (final (key, value) in [
      ('implicitTiling', {}),
      ('contents', []),
      ('viewerRequestVolume', {}),
      ('extensions', {'3DTILES_implicit_tiling': {}}),
    ]) {
      await expectLater(
        parse(tile(refine: 'REPLACE')..[key] = value),
        throwsA(isA<AssetLoadException>()),
      );
    }
  });
  test(
    'limits, malformed transforms and forbidden content references fail',
    () async {
      await expectLater(
        parse(
          tile(refine: 'REPLACE', children: [tile(), tile()]),
          limits: Tiles3DLimits(maxTiles: 2),
        ),
        throwsA(isA<AssetLoadException>()),
      );
      for (final root in [
        tile(),
        tile(refine: 'BAD'),
        tile(refine: 'ADD', error: -1),
        tile(refine: 'ADD', uri: 'https://other.test/secret'),
        tile(refine: 'ADD', transform: List.filled(16, 0.0)),
      ]) {
        await expectLater(parse(root), throwsA(isA<AssetLoadException>()));
      }
    },
  );
  test(
    'GLB and b3dm preserve glTF, Y-up, RTC and affine transform order',
    () async {
      for (final useBinary in [false, true]) {
        final bytes = b3dm(
          triangleModel(),
          rtc: [6378137, 10, 20],
          binaryRtc: useBinary,
        );
        final scope = AssetScope(
          services: AssetServices(resolver: MemoryResolver({'/model': bytes})),
        );
        addTearDown(scope.close);
        final model = await scope
            .load(Tiles3D.content(Uri.parse('https://tiles.test/model')))
            .result;
        final instance = model.instantiate(
          transform: Mat4.compose(
            const Vec3(5, 6, 7),
            Quat.identity,
            const Vec3(2, 2, 2),
          ),
        );
        var world = Mat4.identity();
        Object3D at = instance;
        while (at is! Mesh) {
          world = world * at.localMatrix;
          at = at.children.single;
        }
        // glTF parent translation (1,2,3) -> Z-up (1,-3,2), RTC, then tile scale/translation.
        expect(world.storage[12], closeTo(12756281, 1e-7));
        expect(world.storage[13], closeTo(20, 1e-7));
        expect(world.storage[14], closeTo(51, 1e-7));
        expect(model.decodedBytes, greaterThan(0));
        expect(model.residentBytes, greaterThan(0));
        scope.release(model);
        expect(() => model.instantiate(), throwsStateError);
      }
    },
  );
  test(
    'b3dm truncation, overflow lengths and trailing padding are checked',
    () async {
      final valid = b3dm(triangleModel());
      final corrupt = Uint8List.fromList(valid);
      ByteData.sublistView(corrupt).setUint32(12, 0xffffffff, Endian.little);
      for (final bytes in [
        Uint8List.sublistView(valid, 0, 24),
        corrupt,
        Uint8List.fromList(valid)..last = 99,
      ]) {
        final scope = AssetScope(
          services: AssetServices(resolver: MemoryResolver({'/model': bytes})),
        );
        addTearDown(scope.close);
        await expectLater(
          scope
              .load(Tiles3D.content(Uri.parse('https://tiles.test/model')))
              .result,
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
}
