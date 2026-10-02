import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_capture/zyren_capture.dart';

class FixtureBackend implements RenderBackend {
  final bool supported, failClose;
  final Future<void> Function()? beforeReturn;
  final submissions = <FrameSubmission>[];
  int closes = 0;
  FixtureBackend({
    this.supported = true,
    this.failClose = false,
    this.beforeReturn,
  });
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'test-fixture',
    features: {if (supported) RenderFeature.rgbaReadback},
    limits: DeviceLimits(maxTextureDimension2D: 4096, maxGeometryBytes: 1024),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    submissions.add(submission);
    await beforeReturn?.call();
    final size = submission.size;
    return ReadbackOutput(
      image: ImageData(
        size: size,
        pixels: Uint8List(size.width * size.height * 4),
      ),
      stats: FrameStats(
        frameId: submissions.length,
        physicalSize: size,
        presentationPath: PresentationPath.readback,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: size.width * size.height * 4,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
    closes++;
    if (failClose) throw StateError('close failed');
  }
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zyren-capture-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  CaptureManager manager(FixtureBackend backend, {Scene? scene}) =>
      CaptureManager(
        scene: scene ?? Scene(),
        sceneId: 'scene',
        documentId: 'document',
        outputParent: temp,
        openBackend: () async => backend,
      );

  test(
    'turntable samples fixed poses and times without duplicate end pose',
    () async {
      final backend = FixtureBackend(), capture = manager(backend);
      addTearDown(capture.close);
      final plan = CapturePlan(
        size: PhysicalSize(2, 2),
        frameCount: 4,
        framesPerSecond: 4,
        elevation: 0,
      );
      final job = capture.start(id: 'orbit', plan: plan);
      final artifact = await job.done;
      expect(job.state, CaptureState.completed);
      expect(artifact.frames.length, 4);
      expect(backend.closes, 1);
      expect(
        backend.submissions.map((frame) => frame.time.elapsed.inMicroseconds),
        [0, 250000, 500000, 750000],
      );
      expect(
        plan.cameraAt(0).position.distanceTo(plan.cameraAt(3).position),
        greaterThan(1),
      );
      final manifest =
          jsonDecode(await File(artifact.manifest).readAsString()) as Map;
      expect(manifest['sceneId'], 'scene');
      expect((manifest['frames'] as List).length, 4);
      await capture.close();
      expect(await File(artifact.frames.first).exists(), isTrue);
    },
  );

  test(
    'cancel after first frame removes only its owned output and closes backend',
    () async {
      final sentinel = File('${temp.path}/keep.txt')
        ..writeAsStringSync('host-owned');
      final backend = FixtureBackend(), capture = manager(backend);
      addTearDown(capture.close);
      final job = capture.start(
        id: 'cancel',
        plan: CapturePlan(size: PhysicalSize(2, 2), frameCount: 4),
        onProgress: (_, _) => capture.cancel('cancel'),
      );
      await expectLater(job.done, throwsA(isA<CaptureCancelled>()));
      expect(job.state, CaptureState.cancelled);
      expect(backend.submissions.length, 1);
      expect(backend.closes, 1);
      expect(await temp.list().map((e) => e.path).toList(), [sentinel.path]);
    },
  );

  test(
    'cancellation during opening still closes the eventually created session',
    () async {
      final gate = Completer<RenderBackend>(), backend = FixtureBackend();
      final capture = CaptureManager(
        scene: Scene(),
        sceneId: 's',
        documentId: 'd',
        outputParent: temp,
        openBackend: () => gate.future,
      );
      final job = capture.start(
        id: 'opening',
        plan: CapturePlan(size: PhysicalSize(2, 2)),
      );
      job.cancel();
      gate.complete(backend);
      await expectLater(job.done, throwsA(isA<CaptureCancelled>()));
      expect(backend.closes, 1);
      expect(await temp.list().length, 0);
      await capture.close();
    },
  );

  test(
    'unsupported capture and changed scenes fail without artifact publication',
    () async {
      final unsupported = FixtureBackend(supported: false),
          first = manager(unsupported);
      await expectLater(
        first
            .start(
              id: 'unsupported',
              plan: CapturePlan(size: PhysicalSize(2, 2)),
            )
            .done,
        throwsUnsupportedError,
      );
      expect(unsupported.closes, 1);
      await first.close();
      final scene = Scene();
      final changed = FixtureBackend(
        beforeReturn: () async {
          scene.add(Group());
        },
      );
      final second = manager(changed, scene: scene);
      await expectLater(
        second
            .start(
              id: 'stale',
              plan: CapturePlan(size: PhysicalSize(2, 2)),
            )
            .done,
        throwsStateError,
      );
      expect(changed.closes, 1);
      expect(await temp.list().length, 0);
      await second.close();
    },
  );

  test('sink and close failures clean up and remain failed', () async {
    final backend = FixtureBackend(failClose: true), capture = manager(backend);
    await expectLater(
      capture
          .start(
            id: 'close-failure',
            plan: CapturePlan(size: PhysicalSize(2, 2)),
          )
          .done,
      throwsStateError,
    );
    expect(capture.jobs.single.state, CaptureState.failed);
    expect(await temp.list().length, 0);
    await capture.close();
    final missingParent = Directory('${temp.path}/missing/child'),
        other = FixtureBackend();
    final broken = CaptureManager(
      scene: Scene(),
      sceneId: 's',
      documentId: 'd',
      outputParent: missingParent,
      openBackend: () async => other,
    );
    await expectLater(
      broken
          .start(
            id: 'sink-failure',
            plan: CapturePlan(size: PhysicalSize(2, 2)),
          )
          .done,
      throwsA(isA<FileSystemException>()),
    );
    expect(other.closes, 1);
    await broken.close();
  });

  test('PNG drops row padding and converts premultiplied alpha', () {
    final png = encodeCapturePng(
      ImageData(
        size: PhysicalSize(1, 1),
        rowStride: 8,
        pixels: Uint8List.fromList([64, 32, 0, 128, 11, 22, 33, 44]),
        alphaMode: AlphaMode.premultiplied,
      ),
    );
    var offset = 8;
    while (offset < png.length) {
      final length = ByteData.sublistView(png, offset, offset + 4).getUint32(0);
      final type = ascii.decode(png.sublist(offset + 4, offset + 8));
      if (type == 'IDAT') {
        expect(zlib.decode(png.sublist(offset + 8, offset + 8 + length)), [
          0,
          128,
          64,
          0,
          128,
        ]);
      }
      offset += length + 12;
    }
    expect(
      () => encodeCapturePng(
        ImageData(
          size: PhysicalSize(1, 1),
          pixels: Uint8List(4),
          format: PixelFormat.bgra8,
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test('bounds and single job admission reject unsafe work', () async {
    expect(
      () => CapturePlan(size: PhysicalSize(2, 2), frameCount: 721),
      throwsArgumentError,
    );
    final gate = Completer<void>(),
        backend = FixtureBackend(beforeReturn: () => gate.future);
    final capture = manager(backend);
    final first = capture.start(
      id: 'first',
      plan: CapturePlan(size: PhysicalSize(2, 2)),
    );
    expect(
      () => capture.start(id: 'second', plan: first.plan),
      throwsStateError,
    );
    expect(
      () => capture.start(id: '../invalid', plan: first.plan),
      throwsArgumentError,
    );
    gate.complete();
    await first.done;
    await capture.close();
    expect(
      () => capture.start(id: 'closed', plan: first.plan),
      throwsStateError,
    );
  });
}
