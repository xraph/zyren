import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';

void main() {
  test('release encoder handles first frames and accepted deltas', () async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:zyren/zyren.dart'),
    );
    final package = File.fromUri(library!).parent.parent;
    final directory = await Directory.systemTemp.createTemp('zyren-encoder-');
    try {
      final binary =
          '${directory.path}/encoder${Platform.isWindows ? '.exe' : ''}';
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        '${package.path}/test/fixtures/scene_encoder_aot.dart',
        '-o',
        binary,
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
      final result = await Process.run(binary, []);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('AOT scene encoding passed.'));
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
