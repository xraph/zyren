import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/rendering.dart';

class FakeBackend implements RenderBackend {
  int closeCount = 0;
  final submissions = <FrameSubmission>[];
  Completer<void>? frameGate, closeGate;
  bool failClose = false;
  Object? renderError;
  Set<RenderFeature> additionalFeatures = {};
  final List<String> events;
  FakeBackend([List<String>? events]) : events = events ?? [];
  int maxDimension = 64;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'test-native',
    features: {
      RenderFeature.rgbaReadback,
      RenderFeature.indexedMeshes,
      RenderFeature.selectionOutlines,
      ...additionalFeatures,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: maxDimension,
      maxGeometryBytes: 1000000,
    ),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    submissions.add(submission);
    await frameGate?.future;
    if (renderError != null) throw renderError!;
    final size = submission.size;
    return ReadbackOutput(
      image: ImageData(
        pixels: Uint8List(size.width * size.height * 4),
        size: size,
        rowStride: size.width * 4,
        format: PixelFormat.rgba8,
        colorSpace: ColorSpace.srgb,
        alphaMode: AlphaMode.opaque,
      ),
      stats: FrameStats(
        frameId: submissions.length,
        surfaceEpoch: 0,
        physicalSize: size,
        presentationPath: PresentationPath.readback,
        drawCalls: submission.scene.drawCalls,
        triangles: submission.scene.triangles,
        readbackBytes: size.width * size.height * 4,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
    closeCount++;
    events.add('backend.close');
    await closeGate?.future;
    if (failClose) throw StateError('close failed');
  }
}
