import 'dart:io';

/// Guard the pure Dart packages against accidental platform dependencies.
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.single);
  final allowed = <String, Set<String>>{
    'gpu3d': {'vector_math'},
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
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('Dart core and geospatial import boundaries passed.');
  }
}
