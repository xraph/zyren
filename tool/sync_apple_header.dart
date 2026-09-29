import 'dart:io';

/// Run from the workspace root after changing the native surface ABI.
void main(List<String> args) {
  for (final name in ['zyren.h', 'zyren_resources.h']) {
    final source = File('packages/zyren_native/native/include/$name');
    final target = File('packages/flutter_zyren/darwin/Classes/$name');
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
