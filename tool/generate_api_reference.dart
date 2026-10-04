import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';

// Run from the workspace root. The output is public MDX, never a copy of docs/.
// fvm dart run tool/generate_api_reference.dart [output/reference]
//
// Every public library directly under a package's lib/ is an entry point, so
// a new `lib/agents.dart` shows up without anyone editing this file. A new
// package does need a section below; the run fails until it has one.
const sections = {
  'Core engine': [
    'zyren',
    'flutter_zyren',
    'zyren_native',
    'zyren_effects',
    'zyren_inspector',
  ],
  'Assets and pipelines': [
    'zyren_gltf',
    'zyren_gltf_timeline',
    'zyren_pipeline',
    'zyren_capture',
  ],
  'Tools, review and agents': [
    'zyren_tools',
    'zyren_interaction',
    'flutter_zyren_interaction',
    'zyren_timeline',
    'zyren_engineering',
    'zyren_collaboration',
    'zyren_configurator',
    'zyren_devtools',
    'zyren_agents',
  ],
  'Authoring': ['zyren_studio', 'flutter_zyren_studio'],
  'Geospatial and spatial data': [
    'zyren_geospatial',
    'zyren_geospatial_ocean',
    'zyren_geospatial_ocean_physics',
    'zyren_3d_tiles',
    'zyren_pointclouds',
    'zyren_splats',
    'zyren_scientific',
  ],
  'Simulation, characters and audio': [
    'zyren_physics',
    'zyren_particles',
    'zyren_characters',
    'zyren_navigation',
    'zyren_audio',
    'flutter_zyren_audio',
  ],
  'Games and machine learning': [
    'zyren_game',
    'zyren_game_native',
    'zyren_game_ai',
    'zyren_game_studio',
    'flutter_zyren_game',
    'zyren_ml',
  ],
  'Extended reality': ['zyren_xr'],
};

// Packages large enough that one page per package would be unreadable are
// split by their first directory under lib/src/.
const splitBySourceDirectory = {
  'zyren_game',
  'zyren_game_ai',
  'zyren_game_studio',
};

String anchor(String name) => name.toLowerCase().replaceAll('_', '-');

// Headings are prose to MDX, so an operator such as `<` would open a tag.
String escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('{', '&#123;')
    .replaceAll('}', '&#125;');

String groupFor(String package, Element element) {
  final path = element.firstFragment.libraryFragment!.source.fullName;
  final relative = path.split('/lib/').last;
  if (package == 'zyren') {
    final parts = relative.split('/');
    return parts.length > 2 ? parts[1] : 'core';
  }
  if (package == 'zyren_geospatial') {
    if (relative.contains('/atmosphere/')) return 'atmosphere';
    if (relative.contains('/terrain/')) return 'terrain';
    if (relative.contains('/streaming/') || relative.endsWith('tiling.dart')) {
      return 'streaming';
    }
    return 'globe';
  }
  if (splitBySourceDirectory.contains(package)) {
    final parts = relative.split('/');
    return parts.length > 2 ? parts[1] : 'core';
  }
  return 'api';
}

String description(Element element) {
  final raw = element.documentationComment;
  if (raw == null) return '';
  var value = raw
      .split('\n')
      .map(
        (line) => line
            .replaceFirst(RegExp(r'^\s*/// ?'), '')
            .replaceFirst(RegExp(r'^\s*/\*\* ?'), '')
            .replaceFirst(RegExp(r'\*/\s*$'), '')
            .replaceFirst(RegExp(r'^\s*\* ?'), ''),
      )
      .join('\n');
  value = value.replaceAll(RegExp(r'\{@[^}]+\}'), '');
  // Dartdoc symbol references become inline code; Markdown links stay intact.
  value = value.replaceAllMapped(
    RegExp(r'\[([^\]\n]+)\](?![(:])'),
    (match) => '`${match[1]}`',
  );
  value = value.replaceAll('—', ', ').replaceAll('–', '-');
  // Plain documentation text must not become JSX or MDX expressions.
  var fenced = false;
  return value
      .split('\n')
      .map((line) {
        if (line.trimLeft().startsWith('```')) fenced = !fenced;
        if (fenced || line.trimLeft().startsWith('```')) return line;
        return line
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('{', '&#123;')
            .replaceAll('}', '&#125;');
      })
      .join('\n')
      .trim();
}

Iterable<Element> members(Element element) sync* {
  if (element is InterfaceElement) yield* element.constructors;
  if (element is InstanceElement) {
    yield* element.fields.where((field) => !field.isOriginGetterSetter);
    yield* element.getters.where((getter) => !getter.isOriginVariable);
    yield* element.setters.where((setter) => !setter.isOriginVariable);
    yield* element.methods;
  }
}

/// Public libraries directly under `lib/`, the package-named one first.
List<String> entrypointsOf(String root, String package) {
  final lib = Directory('$root/packages/$package/lib');
  if (!lib.existsSync()) {
    throw StateError('packages/$package has no lib/ directory.');
  }
  final files =
      lib
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.endsWith('.dart') && !name.startsWith('_'))
          .toList()
        ..sort(
          (a, b) => a == '$package.dart'
              ? -1
              : b == '$package.dart'
              ? 1
              : a.compareTo(b),
        );
  return files;
}

/// The one-line pubspec description, used on the index page.
String pubspecDescription(String root, String package) {
  final pubspec = File('$root/packages/$package/pubspec.yaml');
  for (final line in pubspec.readAsLinesSync()) {
    if (line.startsWith('description:')) {
      return line.substring('description:'.length).trim();
    }
  }
  return '';
}

/// Fails when a package directory with a pubspec is missing from [sections].
void checkCoverage(String root) {
  final listed = sections.values.expand((names) => names).toSet();
  final missing = Directory('$root/packages')
      .listSync()
      .whereType<Directory>()
      .where((dir) => File('${dir.path}/pubspec.yaml').existsSync())
      .map((dir) => dir.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .where((name) => !listed.contains(name))
      .toList();
  if (missing.isNotEmpty) {
    throw StateError(
      'Add these packages to a section in tool/generate_api_reference.dart: '
      '${missing.join(', ')}',
    );
  }
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  checkCoverage(root);
  final output = Directory(
    args.isEmpty ? 'docs/content/docs/reference' : args.single,
  );
  final packages = sections.values.expand((names) => names).toList();
  final entrypoints = {
    for (final package in packages) package: entrypointsOf(root, package),
  };
  final paths = [
    for (final package in entrypoints.entries)
      for (final file in package.value)
        '$root/packages/${package.key}/lib/$file',
  ];
  final collection = AnalysisContextCollection(includedPaths: paths);
  final groups = <String, Map<String, Element>>{};
  final imports = <Element, Set<String>>{};
  final locations = <Element, String>{};
  try {
    for (final package in entrypoints.entries) {
      for (final file in package.value) {
        final path = '$root/packages/${package.key}/lib/$file';
        final uri = 'package:${package.key}/$file';
        final result = await collection
            .contextFor(path)
            .currentSession
            .getLibraryByUri(uri);
        if (result is! LibraryElementResult) {
          throw StateError('Cannot resolve $uri: $result');
        }
        for (final exported
            in result.element.exportNamespace.definedNames2.values) {
          final element =
              exported is PropertyAccessorElement && exported.isOriginVariable
              ? exported.variable
              : exported;
          if (!element.isPublic ||
              element.library?.uri.pathSegments.first != package.key) {
            continue;
          }
          final key = '${package.key}/${groupFor(package.key, element)}';
          (groups[key] ??= {})['${element.kind}:${element.name}'] = element;
          (imports[element] ??= {}).add(uri);
          locations[element] =
              '/docs/zyren/reference/$key#${anchor(element.name!)}';
        }
      }
    }
    await output.create(recursive: true);
    final index = StringBuffer(
      '---\ntitle: API reference\ndescription: Public Dart types, constructors, members and defaults for every Zyren package.\n---\n\n',
    );
    index.writeln(
      'Choose a package to find its exported types and members. Signatures and documentation are read from the public Dart libraries by the Dart analyzer, so this reference matches the source it links to. Each type lists the libraries that export it; members inherited from a base class are linked separately.\n',
    );
    index.writeln(
      'For examples and feature support, start with the [guides](/docs/zyren).\n',
    );
    var count = 0;
    var pages = 0;
    for (final section in sections.entries) {
      index.writeln('## ${section.key}\n');
      for (final package in section.value) {
        final keys =
            groups.keys.where((key) => key.startsWith('$package/')).toList()
              ..sort();
        final libraries = entrypoints[package]!
            .map((file) => '`package:$package/$file`')
            .join(', ');
        index.writeln('### $package\n');
        final summary = pubspecDescription(root, package);
        if (summary.isNotEmpty) index.writeln('${escapeText(summary)}\n');
        index.writeln('Libraries: $libraries.\n');
        if (keys.isEmpty) {
          index.writeln('This package exports no public declarations.\n');
          continue;
        }
        final dir = Directory('${output.path}/$package');
        await dir.create(recursive: true);
        await File('${dir.path}/meta.json').writeAsString(
          '${jsonEncode({'title': package, 'pages': keys.map((key) => key.split('/').last).toList()})}\n',
        );
        for (final key in keys) {
          final group = key.split('/').last;
          final label = group == 'api' ? package : group.replaceAll('_', ' ');
          final elements = groups[key]!.values.toList()
            ..sort((a, b) => a.name!.compareTo(b.name!));
          count += elements.length;
          pages++;
          index.writeln(
            '- [$label](/docs/zyren/reference/$key): ${elements.length} exported declarations.',
          );
          final page = StringBuffer(
            '---\ntitle: "$label"\ndescription: "$package $label API signatures, members and parameter defaults."\n---\n\n',
          );
          page.writeln(
            'Public API from `$package`. [Package index](/docs/zyren/reference).\n',
          );
          for (final element in elements) {
            page.writeln('## ${escapeText(element.name!)}\n');
            page.writeln(
              '```dart\n${imports[element]!.map((uri) => "import '$uri';").join('\n')}\n```\n',
            );
            page.writeln(
              '```dart\n${element.displayString(multiline: true)}\n```\n',
            );
            final doc = description(element);
            if (doc.isNotEmpty) page.writeln('$doc\n');
            final source = element.firstFragment.libraryFragment!.source;
            final offset = element.firstFragment.nameOffset ?? 0;
            final line =
                '\n'
                    .allMatches(source.contents.data.substring(0, offset))
                    .length +
                1;
            final sourcePath = source.fullName.substring(root.length + 1);
            page.writeln(
              '[Source](https://github.com/xraph/zyren/blob/main/$sourcePath#L$line)\n',
            );
            if (element is InterfaceElement) {
              final bases = element.allSupertypes
                  .map((type) => type.element)
                  .where((base) => locations.containsKey(base))
                  .toSet();
              if (bases.isNotEmpty) {
                page.writeln(
                  'Inherited members: ${bases.map((base) => '[${base.name}](${locations[base]})').join(', ')}.\n',
                );
              }
            }
            for (final member in members(
              element,
            ).where((member) => member.isPublic)) {
              final name = member.name?.isEmpty == true ? 'new' : member.name;
              page.writeln('### ${escapeText('${element.name}.$name')}\n');
              page.writeln(
                '```dart\n${member.displayString(multiline: true)}\n```\n',
              );
              final doc = description(member);
              if (doc.isNotEmpty) page.writeln('$doc\n');
            }
          }
          await File(
            '${output.path}/$key.mdx',
          ).writeAsString('${page.toString().trimRight()}\n');
        }
        index.writeln();
      }
    }
    await File(
      '${output.path}/index.mdx',
    ).writeAsString('${index.toString().trimRight()}\n');
    await File('${output.path}/meta.json').writeAsString(
      '${jsonEncode({
        'title': 'API reference',
        'pages': ['index', for (final package in packages)
          if (groups.keys.any((key) => key.startsWith('$package/'))) package],
      })}\n',
    );
    stdout.writeln(
      'Generated $count exported declarations across $pages API pages and ${packages.length} packages.',
    );
  } finally {
    await collection.dispose();
  }
}
