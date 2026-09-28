import 'dart:io';

/// Run from the workspace root after changing the native surface ABI.
void main(List<String> args) {
  for (final name in ['gpu3d.h', 'gpu3d_resources.h']) {
    final source = File('packages/gpu3d_native/native/include/$name');
    final target = File('packages/flutter_gpu3d/darwin/Classes/$name');
    if (args.contains('--check')) {
      if (!target.existsSync() ||
          source.readAsStringSync() != target.readAsStringSync()) {
        stderr.writeln('Native ABI header differs: $name');
        exitCode = 1;
      }
    } else {
      source.copySync(target.path);
    }
  }
}
