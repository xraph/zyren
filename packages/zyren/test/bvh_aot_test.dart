import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';

void main() {
  test(
    'release picking handles cold caches, refits and frozen requests',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:zyren/zyren.dart'),
      );
      final package = File.fromUri(library!).parent.parent;
      final directory = await Directory.systemTemp.createTemp('zyren-bvh-');
      try {
        final binary =
            '${directory.path}/bvh${Platform.isWindows ? '.exe' : ''}';
        final compiled = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
          '${package.path}/test/fixtures/bvh_aot.dart',
          '-o',
          binary,
        ]);
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}\n${compiled.stderr}',
        );
        final result = await Process.run(binary, []);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('AOT picking passed.'));
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
