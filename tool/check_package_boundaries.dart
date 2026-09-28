import 'dart:io';

/// Guard the pure Dart packages against accidental platform dependencies.
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.single);
  final allowed = <String, Set<String>>{
    'gpu3d': {'vector_math'},
    'gpu3d_gltf': {'gpu3d'},
    'flutter_geospatial': {'gpu3d'},
  };
  final directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final failures = <String>[];
  for (final package in allowed.entries) {
    final directory = Directory('${root.path}/packages/${package.key}/lib');
    for (final file in directory.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in directive.allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri == 'dart:ui' ||
            uri == 'dart:ffi' ||
            uri.startsWith('package:') &&
                !{
                  package.key,
                  ...package.value,
                }.contains(uri.substring(8).split('/').first)) {
          failures.add('${file.path}: unexpected dependency $uri');
        }
      }
    }
  }
  final canonical = File(
    '${root.path}/packages/gpu3d_native/native/include/gpu3d.h',
  );
  final apple = File(
    '${root.path}/packages/flutter_gpu3d/darwin/Classes/gpu3d.h',
  );
  if (canonical.readAsStringSync() != apple.readAsStringSync()) {
    failures.add(
      'Apple ABI header differs from the native canonical header. '
      'Run dart tool/sync_apple_header.dart.',
    );
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('Package boundaries and Apple ABI header passed.');
  }
}
