import 'dart:typed_data';
import 'gpu_diagnostics.dart';

class PhysicalSize {
  final int width, height;
  PhysicalSize(this.width, this.height) {
    if (width < 1 || height < 1) {
      throw ArgumentError('Physical dimensions must be positive.');
    }
  }
}

enum PixelFormat { rgba8, bgra8 }

enum ColorSpace { srgb, linear }

enum AlphaMode { straight, premultiplied, opaque }

enum PresentationPath { readback, sharedTexture, nativeView }

/// An opaque identity issued and validated by the owning backend.
/// Custom backends may implement this interface; it is never a native pointer.
abstract interface class SurfaceKey {}

sealed class OutputTarget {
  const OutputTarget();
}

final class ReadbackTarget extends OutputTarget {
  final PixelFormat format;
  final ColorSpace colorSpace;
  const ReadbackTarget({
    this.format = PixelFormat.rgba8,
    this.colorSpace = ColorSpace.srgb,
  });
}

final class SurfaceTarget extends OutputTarget {
  final SurfaceKey surface;
  final int epoch;
  SurfaceTarget(this.surface, this.epoch) {
    if (epoch < 0) throw ArgumentError.value(epoch, 'epoch');
  }
}

/// Owned, top-down pixel storage. The producer transfers ownership of [pixels]
/// and must stop mutating it. Consumers receive a read-only view without a copy.
class ImageData {
  final Uint8List pixels;
  final PhysicalSize size;
  final int rowStride;
  final PixelFormat format;
  final ColorSpace colorSpace;
  final AlphaMode alphaMode;
  ImageData({
    required Uint8List pixels,
    required this.size,
    int? rowStride,
    this.format = PixelFormat.rgba8,
    this.colorSpace = ColorSpace.srgb,
    this.alphaMode = AlphaMode.straight,
  }) : pixels = pixels.asUnmodifiableView(),
       rowStride = rowStride ?? size.width * 4 {
    if (this.rowStride < 1 ||
        this.rowStride > pixels.length ||
        size.width > this.rowStride ~/ 4 ||
        pixels.length % this.rowStride != 0 ||
        pixels.length ~/ this.rowStride != size.height) {
      throw ArgumentError(
        'Image storage must match its dimensions and row stride.',
      );
    }
  }
}

/// Unavailable native measurements remain null. CPU timings cover Dart snapshot
/// construction and encoding, not driver work. Upload bytes count geometry, instance and texture data.
/// Immutable source state of a submitted frame, not a pixel visibility claim.
final class FrameSource {
  final int sceneRevision, cameraRevision, cameraRuntimeId;
  final double? logicalWidth, logicalHeight, devicePixelRatio;
  const FrameSource({
    required this.sceneRevision,
    required this.cameraRevision,
    required this.cameraRuntimeId,
    this.logicalWidth,
    this.logicalHeight,
    this.devicePixelRatio,
  });
  FrameSource withViewport({
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
  }) => FrameSource(
    sceneRevision: sceneRevision,
    cameraRevision: cameraRevision,
    cameraRuntimeId: cameraRuntimeId,
    logicalWidth: logicalWidth,
    logicalHeight: logicalHeight,
    devicePixelRatio: devicePixelRatio,
  );
}

class FrameStats {
  final FrameSource? source;
  final int frameId, surfaceEpoch, drawCalls, triangles, readbackBytes;
  final int uploadedBytes, coalescedFrames, droppedFrames, computeDispatches;
  final int? residentBytes;
  final PhysicalSize physicalSize;
  final PresentationPath presentationPath;
  final Duration cpuBuildTime, cpuSubmitTime;
  final Duration? gpuTime;
  final NativeFrameProfile? profile;
  const FrameStats({
    this.source,
    required this.frameId,
    required this.physicalSize,
    required this.presentationPath,
    required this.cpuBuildTime,
    required this.cpuSubmitTime,
    required this.drawCalls,
    required this.triangles,
    required this.readbackBytes,
    required this.uploadedBytes,
    this.surfaceEpoch = 0,
    this.computeDispatches = 0,
    this.coalescedFrames = 0,
    this.droppedFrames = 0,
    this.residentBytes,
    this.gpuTime,
    this.profile,
  });
  FrameStats withSource(FrameSource source) => FrameStats(
    source: source,
    frameId: frameId,
    physicalSize: physicalSize,
    presentationPath: presentationPath,
    cpuBuildTime: cpuBuildTime,
    cpuSubmitTime: cpuSubmitTime,
    drawCalls: drawCalls,
    triangles: triangles,
    readbackBytes: readbackBytes,
    uploadedBytes: uploadedBytes,
    surfaceEpoch: surfaceEpoch,
    computeDispatches: computeDispatches,
    coalescedFrames: coalescedFrames,
    droppedFrames: droppedFrames,
    residentBytes: residentBytes,
    gpuTime: gpuTime,
    profile: profile,
  );
}

sealed class FrameOutput {
  final FrameStats stats;
  const FrameOutput(this.stats);
  FrameOutput withStats(FrameStats stats) => switch (this) {
    ReadbackOutput(:final image) => ReadbackOutput(image: image, stats: stats),
    PresentedOutput(:final surface, :final epoch, :final frameId) =>
      PresentedOutput(
        surface: surface,
        epoch: epoch,
        frameId: frameId,
        stats: stats,
      ),
  };
}

final class ReadbackOutput extends FrameOutput {
  final ImageData image;
  const ReadbackOutput({required this.image, required FrameStats stats})
    : super(stats);
}

final class PresentedOutput extends FrameOutput {
  final SurfaceKey surface;
  final int epoch, frameId;
  const PresentedOutput({
    required this.surface,
    required this.epoch,
    required this.frameId,
    required FrameStats stats,
  }) : super(stats);
}
