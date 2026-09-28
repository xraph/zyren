import 'dart:io';

/// Guard the pure Dart packages against accidental platform dependencies.
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.single);
  final allowed = <String, Set<String>>{
    'packages/gpu3d': {'gpu3d', 'vector_math'},
    'packages/gpu3d_gltf': {'gpu3d_gltf', 'gpu3d'},
    'packages/flutter_geospatial': {'flutter_geospatial', 'gpu3d'},
    'examples/shader_lab/effects_plugin': {'shader_lab_effects', 'gpu3d'},
  };
  final directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final failures = <String>[];
  for (final package in allowed.entries) {
    final directory = Directory('${root.path}/${package.key}/lib');
    for (final file in directory.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final match in directive.allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri == 'dart:ui' ||
            uri == 'dart:ffi' ||
            uri.startsWith('package:') &&
                !package.value.contains(uri.substring(8).split('/').first)) {
          failures.add('${file.path}: unexpected dependency $uri');
        }
        if (package.key == 'examples/shader_lab/effects_plugin' &&
            (uri.startsWith('package:gpu3d/src/') ||
                !uri.contains(':') &&
                    !file.absolute.uri
                        .resolve(uri)
                        .normalizePath()
                        .path
                        .startsWith(
                          directory.absolute.uri.normalizePath().path,
                        ))) {
          failures.add(
            '${file.path}: effects must use public package imports: $uri',
          );
        }
      }
    }
  }
  for (final name in ['gpu3d.h', 'gpu3d_resources.h']) {
    final canonical = File(
      '${root.path}/packages/gpu3d_native/native/include/$name',
    );
    final apple = File(
      '${root.path}/packages/flutter_gpu3d/darwin/Classes/$name',
    );
    if (!apple.existsSync() ||
        canonical.readAsStringSync() != apple.readAsStringSync()) {
      failures.add(
        'Apple ABI header $name differs from the native canonical header. '
        'Run dart tool/sync_apple_header.dart.',
      );
    }
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('Package boundaries and Apple ABI header passed.');
  }
}
