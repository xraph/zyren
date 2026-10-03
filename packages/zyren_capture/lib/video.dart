import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'zyren_capture.dart';

/// A completed opaque H.264/MP4 export. The source PNGs remain host-owned.
final class VideoArtifact {
  final String path, manifest;
  const VideoArtifact(this.path, this.manifest);
}

/// Optional local encoder. Install FFmpeg with libx264 separately and pass its
/// executable path. This does not add an encoder or codec to the renderer.
final class VideoExport {
  final CaptureArtifact source;
  final Directory outputParent;
  final String executable;
  final int framesPerSecond;
  final Duration timeout;
  final void Function(int frames)? onProgress;
  late final Future<VideoArtifact> done;
  Process? _process;
  bool _cancelled = false, _finished = false;
  int completedFrames = 0;
  VideoExport({
    required this.source,
    required this.outputParent,
    this.executable = 'ffmpeg',
    required this.framesPerSecond,
    this.timeout = const Duration(minutes: 10),
    this.onProgress,
  }) {
    if (framesPerSecond < 1 ||
        framesPerSecond > 240 ||
        source.frames.isEmpty ||
        source.frames.length > 720 ||
        timeout <= Duration.zero ||
        timeout > const Duration(hours: 1)) {
      throw ArgumentError('Invalid video rate, frame count or deadline.');
    }
    done = Future(_run);
    done.ignore();
  }
  bool get isFinished => _finished;
  void cancel() {
    if (_finished) return;
    _cancelled = true;
    _process?.kill();
  }

  void _check() {
    if (_cancelled) throw const CaptureCancelled();
  }

  Future<VideoArtifact> _run() async {
    Directory? directory;
    Timer? deadline;
    StreamSubscription<String>? progress, errors;
    var diagnostics = '', timedOut = false;
    try {
      _check();
      final manifestFile = File(source.manifest);
      if (await manifestFile.length() > 2 * 1024 * 1024) {
        throw ArgumentError('Capture manifest exceeds budget.');
      }
      final metadata = jsonDecode(await manifestFile.readAsString()) as Map;
      final plan = metadata['plan'] as Map;
      final width = plan['width'], height = plan['height'];
      if (metadata['schemaVersion'] != 1 ||
          width is! int ||
          height is! int ||
          width < 2 ||
          height < 2 ||
          width.isOdd ||
          height.isOdd ||
          plan['frameCount'] != source.frames.length) {
        throw ArgumentError(
          'MP4 requires a complete sequence with even dimensions.',
        );
      }
      for (var i = 0; i < source.frames.length; i++) {
        final expected = File(
          '${source.directory}/frame_${i.toString().padLeft(4, '0')}.png',
        );
        if (expected.absolute.path != File(source.frames[i]).absolute.path ||
            !await expected.exists()) {
          throw ArgumentError('Capture sequence is missing or out of order.');
        }
      }
      _check();
      directory = await outputParent.createTemp('zyren-video-');
      final path = '${directory.path}/video.mp4';
      _check();
      final process = _process = await Process.start(executable, [
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-framerate',
        '$framesPerSecond',
        '-start_number',
        '0',
        '-i',
        '${source.directory}/frame_%04d.png',
        '-frames:v',
        '${source.frames.length}',
        '-an',
        '-c:v',
        'libx264',
        '-crf',
        '18',
        '-pix_fmt',
        'yuv420p',
        '-movflags',
        '+faststart',
        '-progress',
        'pipe:1',
        path,
      ]);
      // Cancellation can arrive while Process.start is awaiting the child.
      if (_cancelled) process.kill();
      deadline = Timer(timeout, () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
      });
      Object? progressError;
      progress = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('frame=')) {
              completedFrames =
                  (int.tryParse(line.substring(6)) ?? completedFrames).clamp(
                    0,
                    source.frames.length,
                  );
              try {
                onProgress?.call(completedFrames);
              } catch (error) {
                progressError = error;
                process.kill();
              }
            }
          });
      errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((text) {
            diagnostics += text;
            if (diagnostics.length > 16384) {
              diagnostics = diagnostics.substring(diagnostics.length - 16384);
            }
          });
      final progressDone = progress.asFuture<void>(),
          errorsDone = errors.asFuture<void>();
      final code = await process.exitCode;
      await progressDone;
      await errorsDone;
      _check();
      if (timedOut) {
        throw TimeoutException('FFmpeg exceeded export deadline.', timeout);
      }
      if (progressError != null) throw progressError!;
      if (code != 0) throw ProcessException(executable, [], diagnostics, code);
      if (!await File(path).exists() || await File(path).length() == 0) {
        throw StateError('Encoder produced no video.');
      }
      final manifest = '${directory.path}/manifest.json';
      await File(manifest).writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'sourceManifest': source.manifest,
          'frames': source.frames.length,
          'framesPerSecond': framesPerSecond,
          'width': width,
          'height': height,
          'codec': 'h264',
          'container': 'mp4',
          'pixelFormat': 'yuv420p',
          'alpha': 'discarded',
          'audio': 'none',
          'encoder': executable,
        }),
        flush: true,
      );
      _check();
      return VideoArtifact(path, manifest);
    } catch (_) {
      if (directory != null) await directory.delete(recursive: true);
      rethrow;
    } finally {
      deadline?.cancel();
      await progress?.cancel();
      await errors?.cancel();
      _process = null;
      _finished = true;
    }
  }
}
