import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'src/png.dart';
export 'src/png.dart' show encodeCapturePng;

final class CaptureCancelled implements Exception {
  const CaptureCancelled();
}

/// Fixed time and camera sampling. A still uses frameCount 1.
final class CapturePlan {
  final PhysicalSize size;
  final int frameCount, framesPerSecond;
  final Vec3 center;
  final double radius, elevation, startAngle, fieldOfView, near, far;
  CapturePlan({
    required this.size,
    this.frameCount = 1,
    this.framesPerSecond = 30,
    this.center = Vec3.zero,
    this.radius = 5,
    this.elevation = .3,
    this.startAngle = 0,
    this.fieldOfView = math.pi / 3,
    this.near = .1,
    this.far = 1000,
  }) {
    if (size.width > 4096 ||
        size.height > 4096 ||
        frameCount < 1 ||
        frameCount > 720 ||
        framesPerSecond < 1 ||
        framesPerSecond > 240 ||
        !center.isFinite ||
        !radius.isFinite ||
        radius <= 0 ||
        !elevation.isFinite ||
        elevation.abs() >= math.pi / 2 ||
        !startAngle.isFinite) {
      throw ArgumentError('Invalid capture dimensions, sampling or orbit.');
    }
    cameraAt(0); // Validate projection before opening a native session.
  }
  FrameTime timeAt(int index) {
    RangeError.checkValidIndex(index, List.empty(), 'index', frameCount);
    final elapsed = Duration(
      microseconds: (index * 1000000 / framesPerSecond).round(),
    );
    final previous = Duration(
      microseconds: ((index - 1) * 1000000 / framesPerSecond).round(),
    );
    final delta = index == 0 ? Duration.zero : elapsed - previous;
    return FrameTime(
      elapsed: elapsed,
      delta: delta,
      rawDelta: delta,
      index: index,
    );
  }

  PerspectiveCamera cameraAt(int index) {
    if (index < 0 || index >= frameCount) {
      throw RangeError.index(index, List.empty(), 'index', null, frameCount);
    }
    final angle = startAngle + index * 2 * math.pi / frameCount;
    return PerspectiveCamera(
      position:
          center +
          Vec3(
            radius * math.cos(elevation) * math.sin(angle),
            radius * math.sin(elevation),
            radius * math.cos(elevation) * math.cos(angle),
          ),
      target: center,
      fieldOfView: fieldOfView,
      near: near,
      far: far,
    );
  }

  Map<String, Object?> toJson() => {
    'width': size.width,
    'height': size.height,
    'frameCount': frameCount,
    'framesPerSecond': framesPerSecond,
    'center': center.storage,
    'radius': radius,
    'elevation': elevation,
    'startAngle': startAngle,
    'fieldOfView': fieldOfView,
    'near': near,
    'far': far,
  };
}

enum CaptureState { queued, running, completed, cancelled, failed }

final class CaptureArtifact {
  final String jobId, directory, manifest;
  final List<String> frames;
  CaptureArtifact(
    this.jobId,
    this.directory,
    this.manifest,
    Iterable<String> frames,
  ) : frames = List.unmodifiable(frames);
}

final class CaptureJob {
  final String id;
  final CapturePlan plan;
  CaptureState _state = CaptureState.queued;
  int _completedFrames = 0;
  bool _cancelled = false;
  CaptureArtifact? _artifact;
  Object? _error;
  late final Future<CaptureArtifact> done;
  CaptureJob._(this.id, this.plan);
  CaptureState get state => _state;
  int get completedFrames => _completedFrames;
  CaptureArtifact? get artifact => _artifact;
  Object? get error => _error;
  bool get isFinished =>
      _state == CaptureState.completed ||
      _state == CaptureState.cancelled ||
      _state == CaptureState.failed;
  void cancel() {
    if (!isFinished) _cancelled = true;
  }

  void _check() {
    if (_cancelled) throw const CaptureCancelled();
  }
}

/// Owns capture backend sessions and private job directories. Your scene and
/// output parent remain host-owned. Completed files survive close.
final class CaptureManager {
  final Scene scene;
  final String sceneId, documentId;
  final Directory outputParent;
  final Future<RenderBackend> Function() openBackend;
  final int maxJobs;
  final _jobs = <String, CaptureJob>{};
  bool _closed = false;
  int _revision = 0;
  Future<void>? _closing;
  CaptureManager({
    required this.scene,
    required this.sceneId,
    required this.documentId,
    required this.outputParent,
    required this.openBackend,
    this.maxJobs = 32,
  }) {
    if (sceneId.trim().isEmpty ||
        documentId.trim().isEmpty ||
        maxJobs < 1 ||
        maxJobs > 128) {
      throw ArgumentError(
        'Capture identity and bounded job history are required.',
      );
    }
  }
  int get revision => _revision;
  bool get isClosed => _closed;
  List<CaptureJob> get jobs => List.unmodifiable(_jobs.values);

  /// prepareFrame must seek owned animation deterministically, without awaiting.
  /// onProgress receives completed files and may cancel via the returned job.
  CaptureJob start({
    required String id,
    required CapturePlan plan,
    void Function(FrameTime time)? prepareFrame,
    void Function(int completed, int total)? onProgress,
  }) {
    if (_closed) throw StateError('Capture manager has closed.');
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$').hasMatch(id) ||
        _jobs.containsKey(id)) {
      throw ArgumentError('Capture ID must be unique and safe.');
    }
    if (_jobs.length >= maxJobs) {
      throw StateError(
        'Capture history budget reached; forget a completed job.',
      );
    }
    if (_jobs.values.any((job) => !job.isFinished)) {
      throw StateError('A capture is already running.');
    }
    final job = CaptureJob._(id, plan);
    _jobs[id] = job;
    _revision++;
    job.done = Future(() => _run(job, prepareFrame, onProgress));
    job.done.ignore(); // Hosts can inspect failed jobs before awaiting done.
    return job;
  }

  void cancel(String id) {
    final job = _jobs[id];
    if (job == null) throw ArgumentError('Unknown capture job.');
    job.cancel();
    _revision++;
  }

  /// Drops only in-memory history. You own completed files.
  void forget(String id) {
    final job = _jobs[id];
    if (job == null || !job.isFinished) {
      throw StateError('Only completed jobs may be forgotten.');
    }
    _jobs.remove(id);
    _revision++;
  }

  Future<CaptureArtifact> _run(
    CaptureJob job,
    void Function(FrameTime)? prepare,
    void Function(int, int)? progress,
  ) async {
    RenderBackend? backend;
    Directory? directory;
    Object? failure;
    StackTrace? trace;
    final names = <String>[], records = <Map<String, Object?>>[];
    Map<String, Object?>? renderer;
    final startRevision = scene.revision;
    var expectedSceneRevision = startRevision;
    job._state = CaptureState.running;
    _revision++;
    try {
      job._check();
      backend = await openBackend();
      job._check();
      final caps = backend.capabilities;
      if (!caps.supports(RenderFeature.rgbaReadback)) {
        throw UnsupportedError(
          'Backend does not support explicit RGBA capture.',
        );
      }
      if (job.plan.size.width > caps.limits.maxTextureDimension2D ||
          job.plan.size.height > caps.limits.maxTextureDimension2D) {
        throw UnsupportedError(
          'Capture exceeds this native device dimension limit.',
        );
      }
      renderer = {
        'name': caps.name,
        'backend': caps.backend,
        'adapter': caps.adapterName,
      };
      // createTemp atomically creates a fresh child; no caller-selected folder is deleted.
      directory = await outputParent.createTemp('zyren-capture-${job.id}-');
      for (var index = 0; index < job.plan.frameCount; index++) {
        job._check();
        if (scene.revision != expectedSceneRevision) {
          throw StateError('Scene changed outside this capture job.');
        }
        final time = job.plan.timeAt(index), camera = job.plan.cameraAt(index);
        prepare?.call(time);
        final submission = FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: job.plan.size,
          time: time,
        );
        expectedSceneRevision = scene.revision;
        final output = await backend.render(submission);
        job._check();
        if (scene.revision != expectedSceneRevision) {
          throw StateError('Scene changed during native capture.');
        }
        if (output is! ReadbackOutput ||
            output.image.size.width != job.plan.size.width ||
            output.image.size.height != job.plan.size.height) {
          throw StateError('Backend returned an unexpected capture output.');
        }
        final name = 'frame_${index.toString().padLeft(4, '0')}.png';
        await File(
          '${directory.path}/$name',
        ).writeAsBytes(encodeCapturePng(output.image), flush: true);
        job._check();
        names.add(name);
        records.add({
          'file': name,
          'index': index,
          'timeMicroseconds': time.elapsed.inMicroseconds,
          'sceneRevision': expectedSceneRevision,
          'cameraPosition': camera.position.storage,
          'cameraTarget': camera.target.storage,
          'nativeFrameId': output.stats.frameId,
          'coverage':
              'scene pixels only; isolated capture camera; no Flutter overlays',
        });
        job._completedFrames++;
        _revision++;
        progress?.call(job.completedFrames, job.plan.frameCount);
      }
      job._check();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      await backend?.close();
    } catch (error, stack) {
      failure = error;
      trace = stack;
    }
    try {
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
      job._check();
      if (scene.revision != expectedSceneRevision) {
        throw StateError('Scene changed before capture publication.');
      }
      final manifest = File('${directory!.path}/manifest.json');
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 1,
          'jobId': job.id,
          'sceneId': sceneId,
          'documentId': documentId,
          'startSceneRevision': startRevision,
          'plan': job.plan.toJson(),
          'renderer': renderer,
          'pixelFormat': 'rgba8',
          'colorSpace': 'srgb',
          'frames': records,
        }),
        flush: true,
      );
      job._check();
      if (scene.revision != expectedSceneRevision) {
        throw StateError('Scene changed during capture publication.');
      }
      final artifact = CaptureArtifact(
        job.id,
        directory.path,
        manifest.path,
        names.map((name) => '${directory!.path}/$name'),
      );
      job._artifact = artifact;
      job._state = CaptureState.completed;
      _revision++;
      return artifact;
    } catch (error) {
      job._error = error;
      job._state = error is CaptureCancelled
          ? CaptureState.cancelled
          : CaptureState.failed;
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } catch (cleanupError) {
          job._state = CaptureState.failed;
          job._error = StateError(
            'Capture cleanup failed for ${directory.path}: $cleanupError',
          );
        }
      }
      _revision++;
      throw job._error!;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final job in _jobs.values) {
      job.cancel();
    }
    for (final job in _jobs.values) {
      try {
        await job.done;
      } catch (_) {}
    }
    _revision++;
  }
}
