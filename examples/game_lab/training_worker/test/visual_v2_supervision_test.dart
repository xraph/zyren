import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_game_lab_training_worker/visual_v2_supervision.dart';
import '../../../../packages/zyren_capture/test/capture_test.dart'
    show FixtureBackend;

final class _Raster extends FixtureBackend {
  final pixels = Uint8List(84 * 84 * 4),
      metres = Float32List(84 * 84)..fillRange(0, 84 * 84, 4);
  final valid = Uint8List(84 * 84)..fillRange(0, 84 * 84, 1);
  final bool bgra;
  _Raster({this.bgra = false}) {
    for (var i = 0; i < 84 * 84; i++) {
      pixels[i * 4 + 1] = 255;
      pixels[i * 4 + 3] = 255;
    }
  }
  void blue(int left, int right, int top, int bottom) {
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final p = (y * 84 + x) * 4;
        pixels[p] = 0;
        pixels[p + 1] = 0;
        pixels[p + (bgra ? 0 : 2)] = 255;
      }
    }
  }

  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'raster-fixture',
    features: {RenderFeature.rgbaReadback, RenderFeature.metricDepthReadback},
    limits: super.capabilities.limits,
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final original = await super.render(submission) as ReadbackOutput;
    return ReadbackOutput(
      image: ImageData(
        size: submission.size,
        pixels: pixels,
        format: bgra ? PixelFormat.bgra8 : PixelFormat.rgba8,
      ),
      depth: DepthData(size: submission.size, metres: metres, validity: valid),
      stats: original.stats,
    );
  }
}

void main() {
  final profile = VisualNavigationProfile(family: 'guard', mode: 'combined');
  Future<CameraObservation> capture(_Raster backend) async {
    final actor = GameEntityTable().spawn('observer');
    final sensor = CameraSensor(
      profile.camera,
      openBackend: () async => backend,
    );
    try {
      return await sensor.capture(
        snapshot: SensorSnapshot(
          episodeId: 'ep',
          tick: 5,
          worldRevision: 1,
          entities: [SensorEntity(handle: actor, pose: PhysicsPose())],
          colliders: {},
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        ),
        entity: actor,
        scene: Scene(),
      );
    } finally {
      await sensor.close();
    }
  }

  test(
    'complete observed free raster supervises absence without zero target geometry',
    () async {
      final captured = await capture(_Raster());
      final labels = visualV2Supervision(captured, profile);
      expect(labels.fullRasterObservable, isTrue);
      expect(labels.mask.take(6), everyElement(0));
      expect(labels.mask[6], 1);
      expect(labels.mask[7], 1);
      for (var i = 8; i < 56; i += 6) {
        expect(labels.mask.sublist(i, i + 5), everyElement(0));
        expect(labels.mask[i + 5], 1);
        expect(labels.estimate.values[i + 5], 0);
      }
      final hidden = VisualV2TrainingBox.fromCapturedWorld(
        sourceId: 'hidden',
        pose: PhysicsPose(position: const Vec3(100, 0, 0)),
        shape: const BoxShape(Vec3(1, 1, 1)),
        captured: captured,
      );
      expect(
        visualV2Supervision(captured, profile, boxes: [hidden]).toJson(),
        labels.toJson(),
      );
    },
  );
  test(
    'one missing or unclassified pixel prevents absence supervision',
    () async {
      final raster = _Raster()
        ..valid[0] = 0
        ..metres[0] = 0;
      final labels = visualV2Supervision(await capture(raster), profile);
      expect(labels.fullRasterObservable, isFalse);
      expect(labels.mask.take(8), everyElement(0));
      for (var i = 8; i < 56; i += 6) {
        expect(labels.mask[i + 5], 0);
      }
    },
  );
  test(
    'visible depth-supported declared box supplies complete labels; ambiguous boxes do not',
    () async {
      final raster = _Raster()..blue(31, 53, 31, 53);
      final captured = await capture(raster);
      VisualV2TrainingBox box(String id) =>
          VisualV2TrainingBox.fromCapturedWorld(
            sourceId: id,
            pose: PhysicsPose(position: const Vec3(0, .3, 4.35)),
            shape: const BoxShape(Vec3(.5, .5, .1)),
            captured: captured,
          );
      final labels = visualV2Supervision(
        captured,
        profile,
        boxes: [box('wall')],
      );
      expect(labels.visibleComponents, 1);
      expect(labels.mask.sublist(8, 14), everyElement(1));
      expect(labels.estimate.obstacles.first.forward, closeTo(4, 1e-10));
      expect(labels.estimate.obstacles.first.halfWidth, .5);
      for (var i = 14; i < 56; i += 6) {
        expect(labels.mask[i + 5], 0);
      }
      final ambiguous = visualV2Supervision(
        captured,
        profile,
        boxes: [box('a'), box('b')],
      );
      expect(ambiguous.mask.sublist(8, 12), everyElement(0));
      expect(ambiguous.estimate.obstacles.first.sigma, 10);
    },
  );
  test(
    'capture format mismatch and incompatible depth do not fabricate geometry',
    () async {
      await expectLater(
        capture(_Raster(bgra: true)..blue(31, 53, 31, 53)),
        throwsStateError,
      );
      final captured = await capture(_Raster()..blue(31, 53, 31, 53));
      final good = VisualV2TrainingBox.fromCapturedWorld(
        sourceId: 'wall',
        pose: PhysicsPose(position: const Vec3(0, .3, 4.35)),
        shape: const BoxShape(Vec3(.5, .5, .1)),
        captured: captured,
      );
      final wrong = VisualV2TrainingBox.fromCapturedWorld(
        sourceId: 'wrong',
        pose: PhysicsPose(position: const Vec3(0, .3, 10.35)),
        shape: const BoxShape(Vec3(.5, .5, .1)),
        captured: captured,
      );
      expect(
        visualV2Supervision(
          captured,
          profile,
          boxes: [good],
        ).mask.sublist(8, 14),
        everyElement(1),
      );
      expect(
        visualV2Supervision(
          captured,
          profile,
          boxes: [wrong],
        ).mask.sublist(8, 12),
        everyElement(0),
      );
    },
  );
  test(
    'cropped component is positive visible evidence with unknown geometry',
    () async {
      final raster = _Raster()..blue(0, 10, 30, 55);
      final captured = await capture(raster);
      final box = VisualV2TrainingBox.fromCapturedWorld(
        sourceId: 'cropped',
        pose: PhysicsPose(position: const Vec3(2.7, .3, 4.35)),
        shape: const BoxShape(Vec3(.5, .5, .1)),
        captured: captured,
      );
      final labels = visualV2Supervision(captured, profile, boxes: [box]);
      expect(labels.mask.sublist(8, 12), everyElement(0));
      expect(labels.mask.sublist(12, 14), [1, 1]);
      expect(labels.estimate.obstacles.first.sigma, 10);
      expect(labels.estimate.obstacles.first.confidence, 1);
      expect(() => labels.mask[8] = 1, throwsUnsupportedError);
    },
  );
}
