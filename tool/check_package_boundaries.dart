import 'dart:io';

/// Guard package boundaries, including the optional native physics asset.
void main(List<String> args) {
  final root = Directory(args.isEmpty ? '.' : args.single);
  final allowed = <String, Set<String>>{
    'examples/studio': {'zyren_studio_example', 'flutter', 'flutter_zyren', 'flutter_zyren_studio', 'desktop_drop', 'file_selector', 'path_provider', 'crypto', 'zyren_studio', 'zyren_engineering', 'zyren_pipeline', 'zyren_tools', 'zyren_agents', 'zyren_gltf_timeline', 'zyren_timeline', 'zyren_collaboration', 'zyren_game', 'zyren_game_native', 'zyren_game_studio', 'zyren_game_ai', 'zyren_ml', 'zyren_audio', 'zyren_devtools', 'zyren_inspector', 'zyren_geospatial'},
    'examples/game_lab': {'zyren_game_lab', 'flutter', 'flutter_zyren', 'flutter_zyren_game', 'zyren', 'zyren_game', 'zyren_game_native', 'zyren_game_ai', 'zyren_ml', 'zyren_pipeline', 'zyren_gltf', 'zyren_native', 'zyren_physics', 'zyren_audio', 'zyren_interaction', 'crypto'},
    'examples/game_lab/training_worker': {'zyren_game_lab_training_worker', 'zyren_ml', 'zyren_game', 'zyren_game_native', 'zyren_game_ai', 'zyren_physics', 'zyren', 'zyren_native', 'zyren_characters', 'zyren_gltf', 'zyren_gltf_timeline', 'zyren_timeline', 'crypto'},
    'packages/zyren_game_studio': {'zyren_game_studio', 'zyren', 'crypto', 'zyren_game', 'zyren_studio', 'zyren_pipeline', 'flutter', 'flutter_zyren', 'flutter_zyren_studio', 'zyren_agents', 'zyren_navigation', 'zyren_game_native', 'zyren_physics', 'zyren_characters', 'zyren_audio', 'zyren_ml', 'flutter_zyren_game', 'zyren_interaction', 'zyren_game_ai', 'zyren_collaboration', 'zyren_devtools'},
    'packages/zyren_game_ai': {'zyren_game_ai', 'crypto', 'zyren', 'zyren_game', 'zyren_game_native', 'zyren_ml', 'zyren_physics', 'zyren_capture', 'zyren_agents', 'zyren_devtools'},
    'packages/flutter_zyren_audio': {'flutter_zyren_audio', 'flutter'},
    'packages/flutter_zyren_game': {'flutter_zyren_game', 'flutter', 'flutter_zyren', 'flutter_zyren_audio', 'flutter_zyren_interaction', 'zyren', 'zyren_game', 'gamepads'},
    'packages/flutter_zyren_studio': {'flutter_zyren_studio', 'flutter', 'flutter_zyren', 'zyren', 'zyren_studio', 'zyren_agents'},
    'packages/zyren_ml': {'zyren_ml', 'ffi', 'crypto', 'zyren_agents'},
    'packages/zyren_game': {'zyren_game', 'zyren', 'zyren_agents', 'zyren_devtools', 'crypto'},
    'packages/zyren_game_native': {'zyren_game_native', 'zyren_game', 'zyren_physics', 'zyren', 'zyren_characters', 'zyren_interaction', 'zyren_navigation', 'zyren_timeline', 'zyren_audio', 'zyren_particles', 'zyren_gltf', 'zyren_gltf_timeline'},
    'packages/zyren_studio': {'zyren_studio', 'crypto', 'zyren', 'zyren_agents', 'zyren_tools', 'zyren_timeline', 'zyren_engineering'},
    'packages/zyren_scientific': {'zyren_scientific', 'zyren', 'zyren_agents', 'zyren_timeline'},
    'packages/zyren_pipeline': {
      'zyren_pipeline', 'zyren', 'zyren_gltf', 'zyren_agents', 'crypto',
      'zyren_engineering', 'zyren_studio',
    },
    'packages/zyren_navigation': {'zyren_navigation', 'zyren', 'zyren_agents', 'zyren_pipeline', 'zyren_gltf'},
    'packages/zyren_characters': {
      'zyren_characters',
      'zyren',
      'zyren_gltf',
      'zyren_gltf_timeline',
      'zyren_timeline',
      'zyren_agents',
      'zyren_physics',
    },
    'packages/zyren_collaboration': {'zyren_collaboration', 'zyren', 'zyren_agents', 'zyren_engineering'},
    'packages/zyren': {'zyren', 'vector_math', 'dart_earcut'},
    'packages/zyren_gltf': {'zyren_gltf', 'zyren'},
    'packages/zyren_geospatial': {'zyren_geospatial', 'zyren', 'crypto'},
    'packages/zyren_geospatial_ocean': {'zyren_geospatial_ocean', 'zyren_geospatial', 'zyren'},
    'packages/zyren_effects': {'zyren_effects', 'zyren'},
    'packages/zyren_tools': {'zyren_tools', 'zyren'},
    'packages/zyren_devtools': {'zyren_devtools', 'zyren', 'zyren_agents'},
    'packages/zyren_timeline': {'zyren_timeline', 'zyren', 'zyren_agents'},
    'packages/zyren_engineering': {'zyren_engineering', 'zyren', 'crypto'},
    'packages/zyren_particles': {'zyren_particles', 'zyren', 'zyren_agents'},
    'packages/zyren_pointclouds': {'zyren_pointclouds', 'zyren', 'zyren_agents', 'ffi', 'zyren_geospatial', 'zyren_3d_tiles'},
    'packages/zyren_splats': {'zyren_splats', 'zyren', 'zyren_agents', 'zyren_pointclouds'},
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
        final cameraPreview = package.key == 'packages/zyren_game_studio' &&
            file.absolute.uri.normalizePath() ==
                File('${directory.path}/ai.dart').absolute.uri.normalizePath();
        if (uri == 'dart:ui' && !cameraPreview ||
            uri == 'dart:ffi' && !{'packages/zyren_physics', 'packages/zyren_pointclouds', 'packages/zyren_ml'}.contains(package.key) ||
            uri.startsWith('package:') &&
                !package.value.contains(uri.substring(8).split('/').first)) {
          failures.add('${file.path}: unexpected dependency $uri');
        }
        if ((package.key == 'examples/shader_lab/effects_plugin' ||
                package.key == 'packages/zyren_inspector' ||
                package.key == 'packages/zyren_studio') &&
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
