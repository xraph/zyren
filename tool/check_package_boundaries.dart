import 'dart:io';

/// Guard package boundaries, including the optional native physics asset.
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.single);
  final allowed = <String, Set<String>>{
    'packages/zyren_scientific': {'zyren_scientific', 'zyren', 'zyren_agents', 'zyren_timeline'},
    'packages/zyren_pipeline': {
      'zyren_pipeline', 'zyren', 'zyren_gltf', 'zyren_agents', 'crypto',
    },
    'packages/zyren_navigation': {'zyren_navigation', 'zyren', 'zyren_agents'},
    'packages/zyren_characters': {
      'zyren_characters',
      'zyren',
      'zyren_gltf',
      'zyren_gltf_timeline',
      'zyren_timeline',
      'zyren_agents',
    },
    'packages/zyren_collaboration': {'zyren_collaboration', 'zyren', 'zyren_agents', 'zyren_engineering'},
    'packages/zyren': {'zyren', 'vector_math', 'dart_earcut'},
    'packages/zyren_gltf': {'zyren_gltf', 'zyren'},
    'packages/zyren_geospatial': {'zyren_geospatial', 'zyren'},
    'packages/zyren_effects': {'zyren_effects', 'zyren'},
    'packages/zyren_tools': {'zyren_tools', 'zyren'},
    'packages/zyren_devtools': {'zyren_devtools', 'zyren', 'zyren_agents'},
    'packages/zyren_timeline': {'zyren_timeline', 'zyren', 'zyren_agents'},
    'packages/zyren_engineering': {'zyren_engineering', 'zyren', 'crypto'},
    'packages/zyren_particles': {'zyren_particles', 'zyren', 'zyren_agents'},
    'packages/zyren_physics': {'zyren_physics', 'zyren', 'ffi', 'zyren_agents'},
    'packages/zyren_gltf_timeline': {
      'zyren_gltf_timeline',
      'zyren_gltf',
      'zyren_timeline',
      'zyren_agents',
      'zyren',
    },
    'packages/zyren_3d_tiles': {
      'zyren_3d_tiles',
      'zyren',
      'zyren_gltf',
      'zyren_geospatial',
    },
    'packages/zyren_inspector': {'zyren_inspector', 'flutter', 'flutter_zyren'},
    'examples/shader_lab/effects_plugin': {'shader_lab_effects', 'zyren'},
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
            uri == 'dart:ffi' && package.key != 'packages/zyren_physics' ||
            uri.startsWith('package:') &&
                !package.value.contains(uri.substring(8).split('/').first)) {
          failures.add('${file.path}: unexpected dependency $uri');
        }
        if ((package.key == 'examples/shader_lab/effects_plugin' ||
                package.key == 'packages/zyren_inspector') &&
            (uri.startsWith('package:zyren/src/') ||
                uri.startsWith('package:flutter_zyren/src/') ||
                !uri.contains(':') &&
                    !file.absolute.uri
                        .resolve(uri)
                        .normalizePath()
                        .path
                        .startsWith(
                          directory.absolute.uri.normalizePath().path,
                        ))) {
          failures.add(
            '${file.path}: extensions must use public package imports: $uri',
          );
        }
      }
    }
  }
  for (final name in ['zyren.h', 'zyren_resources.h']) {
    final canonical = File(
      '${root.path}/packages/zyren_native/native/include/$name',
    );
    final apple = File(
      '${root.path}/packages/flutter_zyren/darwin/Classes/$name',
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
