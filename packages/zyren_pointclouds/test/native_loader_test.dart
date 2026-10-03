import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'package:zyren_pointclouds/native.dart';

Future<Uint8List> fixture(String name) => File(
  '${Directory('test/fixtures').existsSync() ? 'test/fixtures' : 'packages/zyren_pointclouds/test/fixtures'}/$name',
).readAsBytes();
final source = Uri.parse('asset:survey');
const loader = NativePointCloudLoader(sourceVersion: 'v1');

class Cancellation implements LoadCancellation {
  final _callbacks = <void Function()>[];
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    _callbacks.add(callback);
    return Registration(() => _callbacks.remove(callback));
  }

  void cancel() {
    isCancelled = true;
    for (final callback in List.of(_callbacks)) {
      callback();
    }
  }
}

void main() {
  for (final name in ['survey.las', 'survey.laz', 'survey14.laz']) {
    test(
      '$name preserves source precision, classifications, returns and CRS',
      () async {
        final data = await loader.parse(await fixture(name), sourceUri: source);
        expect(data.count, 3);
        expect(data.pointAt(1).x, closeTo(1e9 + .001, 1e-7));
        expect(data.classificationAt(1), 2);
        expect(data.attributesAt(1)['intensity'], 1201);
        expect(data.attributesAt(1)['returnCount'], 2);
        expect(data.attributesAt(1)['color'], [65535, 32768, 1]);
        expect(data.attributesAt(2)['withheld'], true);
        expect(data.metadata['scale'], [.001, .001, .001]);
        expect(data.metadata['coordinateReferenceWkt'], 'LOCAL_CS["Fixture"]');
        expect(data.metadata['units'], isNull);
        final selected = data.select([2, 0]);
        expect(selected.identityAt(0), (source, 'v1', 2));
        expect(selected.attributesAt(0)['withheld'], true);
        expect(
          () => (selected.metadata['scale'] as List)[0] = 7,
          throwsUnsupportedError,
        );
        final scene = ScenePointCloud(data: selected);
        final hit = scene.pick(
          Ray(data.pointAt(2) + Vec3(0, 0, 2), Vec3(0, 0, -1)),
          radius: .01,
        );
        expect(hit?.identity.$3, 2);
        expect(hit?.dataIndex, 0);
        scene.close();
      },
    );
  }
  test(
    'E57 retains scan identities, poses, raw intensity and skipped ordinals',
    () async {
      final data = await loader.parse(
        await fixture('scans.e57'),
        sourceUri: source,
      );
      expect(data.count, 4);
      expect(List.generate(data.count, (i) => data.identityAt(i).$3), [
        0,
        2,
        3,
        5,
      ]);
      expect(data.pointAt(0), Vec3(110, 2, 3));
      expect(data.pointAt(2), Vec3(120, 2, 3));
      expect(data.metadata['skippedInvalidRecords'], 2);
      expect(data.metadata['units'], 'metres');
      expect(data.attributesAt(2)['scanIndex'], 1);
      expect((data.attributesAt(0)['rawValues'] as List)[4], 0.12345678912345);
      expect((data.metadata['scans'] as List)[1]['guid'], 'fixture-scan-1');
    },
  );
  test(
    'native loader rejects malformed sections, count and attribute budgets',
    () async {
      final las = await fixture('survey.las');
      final e57 = await fixture('scans.e57');
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        Uint8List.sublistView(las, 0, 220),
        Uint8List.sublistView(e57, 0, 100),
        Uint8List.sublistView(las, 0, las.length - 1),
      ]) {
        await expectLater(
          loader.parse(bytes, sourceUri: source),
          throwsA(isA<AssetLoadException>()),
        );
      }
      final huge = Uint8List.fromList(las);
      ByteData.sublistView(huge).setUint64(247, 1000000000, Endian.little);
      await expectLater(
        loader.parse(huge, sourceUri: source),
        throwsA(isA<AssetLoadException>()),
      );
      const bounded = NativePointCloudLoader(
        sourceVersion: 'v1',
        limits: PointCloudLimits(maxPoints: 2),
      );
      await expectLater(
        bounded.parse(las, sourceUri: source),
        throwsA(isA<AssetLoadException>()),
      );
      const attrs = NativePointCloudLoader(
        sourceVersion: 'v1',
        limits: PointCloudLimits(maxAttributeBytes: 2),
      );
      await expectLater(
        attrs.parse(las, sourceUri: source),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );
  test('cancellation wins and the decoder remains usable afterwards', () async {
    final bytes = await fixture('survey.laz');
    final cancellation = Cancellation();
    final pending = loader.parse(
      bytes,
      sourceUri: source,
      cancellation: cancellation,
    );
    cancellation.cancel();
    await expectLater(pending, throwsA(isA<LoadCancelled>()));
    expect((await loader.parse(bytes, sourceUri: source)).count, 3);
  });
}
