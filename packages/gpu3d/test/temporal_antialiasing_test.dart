import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'frame_graph_test.dart' show FrameBackend;
import 'support/fakes.dart' show TestPlugin;

void main() {
  test('temporal options and HDR coverage are validated before encoding', () {
    expect(() => TemporalAAOptions(historyWeight: 1), throwsArgumentError);
    expect(
      () => TemporalAAOptions(depthTolerance: double.nan),
      throwsArgumentError,
    );
    expect(() => TemporalAAOptions(maxBytes: 0), throwsArgumentError);
    final scene = Scene(),
        camera = PerspectiveCamera(),
        size = PhysicalSize(31, 31);
    expect(
      () => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: size,
        temporalAA: TemporalAAOptions(),
      ),
      throwsArgumentError,
    );
    expect(
      () => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: size,
        colorPipeline: ColorPipeline(sampleCount: 4),
        temporalAA: TemporalAAOptions(),
      ),
      throwsArgumentError,
    );
    final capture = FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: size,
      colorPipeline: ColorPipeline(),
      temporalAA: TemporalAAOptions(),
    );
    expect(() => capture.toNativePacket(), throwsUnsupportedError);
    final packet = ScenePacketEncoder(viewId: 1).encode(capture);
    expect(ByteData.sublistView(packet.bytes).getUint32(4, Endian.little), 31);
    expect(capture.withGraph(null).temporalAA, same(capture.temporalAA));
  });
  test(
    'temporal demand counts accepted frames and releases on disable or detach',
    () async {
      final backend = TemporalBackend(), temporal = TemporalAntialiasing();
      var demands = 0;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        plugins: [temporal],
        backendFactory: () async => backend,
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      Future<void> draw() async {
        await engine.renderFrame(
          elapsed: Duration.zero,
          width: 8,
          height: 8,
          colorPipeline: ColorPipeline(),
        );
      }

      try {
        await draw();
        expect(demands, 1);
        backend.fail = true;
        await expectLater(draw(), throwsStateError);
        expect(demands, 1);
        backend.fail = false;
        for (var i = 0; i < 6; i++) {
          await draw();
        }
        expect(demands, 1);
        await draw();
        expect(demands, 0);
        engine.camera.position = const Vec3(1, 0, 5);
        await draw();
        expect(demands, 1);
        temporal.enabled = false;
        expect(demands, 0);
        await draw();
        expect(backend.last!.temporalAA, isNull);
        temporal.enabled = true;
        await draw();
        expect(demands, 1);
        final generation = backend.last!.temporalReset;
        temporal.reset();
        await draw();
        expect(backend.last!.temporalReset, greaterThan(generation));
        engine.invalidateHistory();
        await draw();
        expect(backend.last!.temporalReset, greaterThan(generation + 1));
      } finally {
        await engine.dispose();
      }
      expect(demands, 0);
    },
  );
  test(
    'temporal binding has one provider and unsupported backends fail at attach',
    () async {
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => FrameBackend(),
          plugins: [TemporalAntialiasing()],
        ),
        throwsA(isA<SceneException>()),
      );
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => TemporalBackend(),
          plugins: [
            TemporalAntialiasing(),
            TestPlugin(
              'duplicate',
              [],
              onAttach: (context) {
                context.temporal;
              },
            ),
          ],
        ),
        throwsStateError,
      );
    },
  );
}

class TemporalBackend extends FrameBackend {
  bool fail = false;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'temporal test',
    features: {RenderFeature.temporalAntialiasing, RenderFeature.hdrColor},
    limits: DeviceLimits(maxTextureDimension2D: 4096, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    if (fail) throw StateError('rejected test frame');
    return super.render(submission);
  }
}
