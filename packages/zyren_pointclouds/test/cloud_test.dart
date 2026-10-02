import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';

final source = Uri.parse('file:///survey.xyz');
Uint8List bytes(String value) => Uint8List.fromList(ascii.encode(value));
TypeMatcher<AssetLoadException> error(AssetLoadError code) =>
    isA<AssetLoadException>().having((e) => e.code, 'code', code);

class Resolver implements ByteSourceResolver {
  final Uint8List data;
  Resolver(this.data);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: data);
}

class Cancellation implements LoadCancellation {
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) => Registration(() {});
}

void main() {
  test(
    'core asset scope retains doubles, source version and record ordinal',
    () async {
      final scope = AssetScope(
        services: AssetServices(
          resolver: Resolver(
            bytes('# survey\r\n1000000000.001 2 3\r\n\n1000000000.002 2 3'),
          ),
        ),
      );
      final task = scope.load(
        AssetRequest(
          uri: source,
          version: 'v7',
          loader: const XyzPointCloudLoader(sourceVersion: 'v7'),
        ),
      );
      final data = await task.result;
      expect(data.count, 2);
      expect(data.coordinateBytes, 48);
      expect(data.pointAt(0).x, 1000000000.001);
      expect(data.identityAt(1), (source, 'v7', 1));
      await scope.close();
    },
  );

  test('budgets reject source, line, records and decoded payload', () async {
    for (final limits in [
      const PointCloudLimits(maxSourceBytes: 5),
      const PointCloudLimits(maxLineBytes: 4),
      const PointCloudLimits(maxPoints: 1),
      const PointCloudLimits(maxCoordinateBytes: 24),
    ]) {
      await expectLater(
        XyzPointCloudLoader(
          sourceVersion: 'v1',
          limits: limits,
        ).parse(bytes('1 2 3\n4 5 6'), sourceUri: source),
        throwsA(error(AssetLoadError.limitExceeded)),
      );
    }
    final scope = AssetScope(
      services: AssetServices(
        resolver: Resolver(bytes('1 2 3\n4 5 6')),
        limits: const AssetLimits(maxDecodedBytes: 24),
      ),
    );
    await expectLater(
      scope
          .load(
            AssetRequest(
              uri: source,
              loader: const XyzPointCloudLoader(sourceVersion: 'v1'),
            ),
          )
          .result,
      throwsA(error(AssetLoadError.limitExceeded)),
    );
    await scope.close();
  });

  test(
    'malformed, nonfinite, empty and unknown columns fail explicitly',
    () async {
      for (final value in [
        '',
        '# nothing',
        '1 NaN 3',
        '1 Infinity 3',
        '1 2',
        '1 2 3 4',
        'a 2 3',
      ]) {
        await expectLater(
          const XyzPointCloudLoader(
            sourceVersion: 'v1',
          ).parse(bytes(value), sourceUri: source),
          throwsA(error(AssetLoadError.invalidData)),
        );
      }
    },
  );

  test(
    'cancellation interrupts a cooperative parse before retaining all records',
    () async {
      final token = Cancellation();
      final loading = const XyzPointCloudLoader(sourceVersion: 'v1').parse(
        bytes(List.filled(10000, '1 2 3').join('\n')),
        sourceUri: source,
        cancellation: token,
      );
      token.isCancelled = true;
      await expectLater(loading, throwsA(isA<LoadCancelled>()));
    },
  );

  test(
    'recentered display and source query preserve millimetre differences',
    () {
      final data = PointCloudData(
        sourceUri: source,
        sourceVersion: 'v1',
        points: [const Vec3(1e9, 0, 0), const Vec3(1000000000.001, 0, 0)],
      );
      final cloud = ScenePointCloud(data: data, displayErrorLimit: 1e-7);
      expect(cloud.maxDisplayError, lessThan(1e-7));
      final hit = cloud.pick(
        Ray(const Vec3(1000000000.001, 0, 10), const Vec3(0, 0, -1)),
        radius: .0001,
      )!;
      expect(hit.identity, (source, 'v1', 1));
      expect(hit.sourcePoint, data.pointAt(1));
      expect(hit.worldPoint.x, data.pointAt(1).x);
      expect(
        () => ScenePointCloud(
          data: data,
          sourceOrigin: Vec3.zero,
          displayErrorLimit: .0001,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'world transforms, clipping, near/far, visibility and close constrain queries',
    () {
      final data = PointCloudData(
        sourceUri: source,
        sourceVersion: 'v1',
        points: [Vec3.zero, const Vec3(1, 0, 0)],
      );
      final cloud = ScenePointCloud(data: data);
      final scene = Scene();
      final parent = scene.add(
        Group()
          ..position = const Vec3(3, 0, 0)
          ..scale = const Vec3(2, 2, 2),
      );
      parent.add(cloud.object);
      final ray = Ray(const Vec3(5, 0, 10), const Vec3(0, 0, -1));
      expect(cloud.pick(ray, radius: .1)!.identity.$3, 1);
      expect(cloud.pick(ray, radius: .1, far: 9), isNull);
      expect(
        cloud.pick(
          ray,
          radius: .1,
          clippingPlanes: [
            ClippingPlane(normal: const Vec3(1, 0, 0), offset: 6),
          ],
        ),
        isNull,
      );
      parent.visible = false;
      expect(cloud.pick(ray, radius: .1), isNull);
      cloud.close();
      cloud.close();
      expect(parent.children, isEmpty);
      expect(() => cloud.pick(ray, radius: .1), throwsStateError);
    },
  );
}
