import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/zyren_capture.dart';
import 'package:zyren_capture/video.dart';

void main() {
  test(
    'FFmpeg exports fixed-rate MP4, cancellation/failure preserve source',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-video-test-');
      addTearDown(() => dir.delete(recursive: true));
      final input = await Directory('${dir.path}/input').create();
      final frames = <String>[];
      for (var i = 0; i < 4; i++) {
        final name = '${input.path}/frame_${i.toString().padLeft(4, '0')}.png';
        final pixels = Uint8List(16 * 16 * 4);
        for (var p = 0; p < pixels.length; p += 4) {
          pixels[p] = i * 60;
          pixels[p + 3] = 255;
        }
        await File(name).writeAsBytes(
          encodeCapturePng(
            ImageData(size: PhysicalSize(16, 16), pixels: pixels),
          ),
        );
        frames.add(name);
      }
      final manifest = await File('${input.path}/manifest.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'plan': {'width': 16, 'height': 16, 'frameCount': 4},
        }),
      );
      final source = CaptureArtifact(
        'fixture',
        input.path,
        manifest.path,
        frames,
      );
      final job = VideoExport(
        source: source,
        outputParent: dir,
        framesPerSecond: 12,
      );
      final artifact = await job.done;
      expect(await File(artifact.path).length(), greaterThan(100));
      expect(job.isFinished, true);
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=nb_frames,r_frame_rate,width,height',
        '-of',
        'json',
        artifact.path,
      ]);
      expect(probe.exitCode, 0);
      final stream =
          (jsonDecode(probe.stdout as String)['streams'] as List).single;
      expect(stream['nb_frames'], '4');
      expect(stream['r_frame_rate'], '12/1');
      late VideoExport during;
      during = VideoExport(
        source: source,
        outputParent: dir,
        framesPerSecond: 12,
        onProgress: (_) => during.cancel(),
      );
      await expectLater(during.done, throwsA(isA<CaptureCancelled>()));
      final cancelled = VideoExport(
        source: source,
        outputParent: dir,
        framesPerSecond: 12,
      )..cancel();
      await expectLater(cancelled.done, throwsA(isA<CaptureCancelled>()));
      final failed = VideoExport(
        source: source,
        outputParent: dir,
        framesPerSecond: 12,
        executable: '/usr/bin/false',
      );
      await expectLater(failed.done, throwsA(isA<ProcessException>()));
      expect(await dir.list().length, 2);
      expect(await input.list().length, 5);
    },
    skip: Platform.environment['RUN_FFMPEG'] != '1',
  );
}
