import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';

// Checks the guides in docs/content/docs against the code they describe.
//
//   fvm dart tool/check_docs.dart [docs/content/docs/physics.mdx ...]
//
// Three things fail the run:
//
// - a ```dart fence that does not compile against the workspace packages,
// - a `TypeName` or `TypeName.member` in prose that no package or SDK library
//   declares,
// - a /docs link to a page that does not exist.
//
// A fence is split into imports, top-level declarations and statements.
// Statements are wrapped in an async function, so a snippet can show three
// lines of setup without a main(). Names a page's snippets take for granted
// (a `controller`, a `mesh`) are declared in docs/tools/samples/<page>.dart,
// together with the imports a reader of that page already has. Pages without
// a prelude get the core and Flutter imports only.
//
// The API reference under reference/ is generated from the analyzer and is
// skipped here.

const docsRoot = 'docs/content/docs';
const preludeRoot = 'docs/tools/samples';
// One directory per run, so two checks running at once cannot delete each
// other's samples.
final generatedRoot = '.dart_tool/zyren_doc_samples/$pid';

const defaultImports = [
  "import 'package:flutter_zyren/flutter_zyren.dart';",
  "import 'package:zyren/zyren.dart';",
];

// Lints that fire on any illustrative snippet and say nothing about whether
// the API it shows is real.
const ignoredCodes = {
  'unused_local_variable',
  'unused_import',
  'unnecessary_import',
  'unused_element',
  'dead_code',
  'depend_on_referenced_packages',
  'avoid_print',
  'unused_field',
  'unused_catch_clause',
  'no_leading_underscores_for_local_identifiers',
};

// SDK libraries whose names a guide may mention in prose.
const sdkLibraries = [
  'dart:core',
  'dart:async',
  'dart:typed_data',
  'dart:io',
  'dart:math',
  'dart:ui',
  'dart:isolate',
  'dart:ffi',
  'package:flutter/material.dart',
  'package:flutter/widgets.dart',
  'package:flutter/services.dart',
  'package:flutter/gestures.dart',
  'package:flutter/scheduler.dart',
];

// Backticked words that look like Dart types but name files, tools or
// formats. Keep this short; a real type belongs in a package.
const proseAllowlist = {
  'Podfile',
  'Info.plist',
  'Cargo.toml',
  'Cargo.lock',
  'CMakeLists.txt',
  'AndroidManifest.xml',
  'Package.swift',
  'Runner',
  'Runner.xcworkspace',
  'MainActivity',
  'AppDelegate',
  'Makefile',
};

final declarationStart = RegExp(
  r'^(?:@\w|(?:abstract\s+|base\s+|final\s+|sealed\s+|interface\s+|mixin\s+)*(?:class|enum|mixin|extension|typedef)\b'
  r'|(?:Future|FutureOr|Stream|Iterable|List|Map|Set|void|bool|int|double|num|String|Widget|[A-Z]\w*)(?:<[^=]*>)?\??\s+[A-Za-z_]\w*\s*(?:<[^>()]*>)?\s*\()',
);

class Fence {
  Fence(this.page, this.line, this.lines);
  final String page;
  final int line;
  final List<String> lines;
}

class Unit {
  Unit(this.fence, this.path, this.source, this.lineMap);
  final Fence fence;
  final String path;
  final String source;

  /// Generated line (1-based) to page line, or null for scaffolding.
  final Map<int, int> lineMap;
}

List<Fence> fencesOf(String page, List<String> lines) {
  final fences = <Fence>[];
  List<String>? current;
  var start = 0;
  var indent = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (current == null) {
      if (RegExp(r'^```dart\b').hasMatch(trimmed)) {
        current = [];
        start = i + 2;
        indent = line.length - trimmed.length;
      }
      continue;
    }
    if (trimmed.startsWith('```')) {
      fences.add(Fence(page, start, current));
      current = null;
      continue;
    }
    current.add(
      line.length >= indent && line.substring(0, indent).trim().isEmpty
          ? line.substring(indent)
          : line.trimLeft(),
    );
  }
  return fences;
}

int tripleQuotes(String line) =>
    "'''".allMatches(line).length + '"""'.allMatches(line).length;

int braceDelta(String line) {
  var delta = 0;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '/' && i + 1 < line.length && line[i + 1] == '/') {
      break;
    } else if (c == '{') {
      delta++;
    } else if (c == '}') {
      delta--;
    }
  }
  return delta;
}

/// Splits a fence into import lines, top-level declarations and statements,
/// each as (fence line index, text) pairs.
({
  List<(int, String)> imports,
  List<(int, String)> declarations,
  List<(int, String)> statements,
})
split(List<String> lines) {
  final imports = <(int, String)>[];
  final declarations = <(int, String)>[];
  final statements = <(int, String)>[];
  // A line inside a triple-quoted string is text, whatever it looks like.
  // WGSL in a shader source starts lines with `@compute`, for one.
  void takeString(
    List<(int, String)> bucket,
    int start,
    void Function(int) at,
  ) {
    var open = tripleQuotes(lines[start]).isOdd;
    var j = start;
    while (open && j + 1 < lines.length) {
      j++;
      bucket.add((j, lines[j]));
      open = tripleQuotes(lines[j]).isOdd ? !open : open;
    }
    at(j);
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.startsWith('import ') || line.startsWith('export ')) {
      while (true) {
        imports.add((i, lines[i]));
        if (lines[i].trimRight().endsWith(';') || i + 1 >= lines.length) break;
        i++;
      }
      i++;
      continue;
    }
    if (declarationStart.hasMatch(line) && !line.trimRight().endsWith(';')) {
      var depth = 0;
      var opened = false;
      while (i < lines.length) {
        declarations.add((i, lines[i]));
        if (tripleQuotes(lines[i]).isOdd) {
          takeString(declarations, i, (end) => i = end);
        }
        depth += braceDelta(lines[i]);
        if (lines[i].contains('{')) opened = true;
        final done =
            (opened && depth <= 0) ||
            (!opened && depth <= 0 && lines[i].trimRight().endsWith(';'));
        i++;
        if (done) break;
      }
      continue;
    }
    if (line.startsWith('typedef ')) {
      declarations.add((i, line));
      i++;
      continue;
    }
    statements.add((i, line));
    takeString(statements, i, (end) => i = end);
    i++;
  }
  return (imports: imports, declarations: declarations, statements: statements);
}

String relativePage(String path) =>
    path.substring(docsRoot.length + 1).replaceAll(RegExp(r'\.mdx$'), '');

Unit buildUnit(Fence fence, int index) {
  final relative = relativePage(fence.page);
  final preludeFile = File('$preludeRoot/$relative.dart');
  final prelude = preludeFile.existsSync()
      ? preludeFile.readAsLinesSync()
      : <String>[];
  final parts = split(fence.lines);
  final out = <String>[];
  final lineMap = <int, int>{};
  void emit(String text, [int? fenceIndex]) {
    out.add(text);
    if (fenceIndex != null) lineMap[out.length] = fence.line + fenceIndex;
  }

  emit(
    '// GENERATED by tool/check_docs.dart from ${fence.page}:${fence.line}.',
  );
  emit('// ignore_for_file: ${ignoredCodes.join(', ')}');
  final seen = <String>{};
  final preludeImports = prelude.where((l) => l.startsWith('import ')).toList();
  for (final line in preludeImports.isEmpty ? defaultImports : preludeImports) {
    if (seen.add(line.trim())) emit(line);
  }
  for (final (at, line) in parts.imports) {
    if (seen.add(line.trim())) emit(line, at);
  }
  for (final line in prelude.where((l) => !l.startsWith('import '))) {
    emit(line);
  }
  for (final (at, line) in parts.declarations) {
    emit(line, at);
  }
  if (parts.statements.any((entry) => entry.$2.trim().isNotEmpty)) {
    emit('Future<void> docSample$index() async {');
    for (final (at, line) in parts.statements) {
      emit(line, at);
    }
    emit('}');
  }
  final name = '${relative.replaceAll('/', '__')}__$index.dart';
  return Unit(fence, '$generatedRoot/$name', '${out.join('\n')}\n', lineMap);
}

/// Every name a guide may mention: exports of every package entry point and
/// the SDK libraries, plus the members of each exported interface.
Future<(Set<String>, Map<String, Set<String>>)> knownSymbols(
  AnalysisContextCollection collection,
  String anchorPath,
) async {
  final types = <String>{};
  final members = <String, Set<String>>{};
  final extensions = <ExtensionElement>[];
  final session = collection.contextFor(anchorPath).currentSession;
  final uris = <String>[
    ...sdkLibraries,
    for (final dir in Directory('packages').listSync().whereType<Directory>())
      if (File('${dir.path}/pubspec.yaml').existsSync() &&
          Directory('${dir.path}/lib').existsSync())
        for (final file in Directory(
          '${dir.path}/lib',
        ).listSync().whereType<File>())
          if (file.path.endsWith('.dart'))
            'package:${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}/'
                '${file.uri.pathSegments.last}',
  ];
  for (final uri in uris) {
    final result = await session.getLibraryByUri(uri);
    if (result is! LibraryElementResult) continue;
    for (final entry in result.element.exportNamespace.definedNames2.entries) {
      types.add(entry.key);
      final element = entry.value;
      if (element is ExtensionElement) {
        extensions.add(element);
        continue;
      }
      if (element is! InterfaceElement) continue;
      final names = members[entry.key] ??= {};
      for (final type in [
        element,
        ...element.allSupertypes.map((t) => t.element),
      ]) {
        for (final c in type.constructors) {
          final name = c.name;
          names.add(name == null || name.isEmpty ? 'new' : name);
        }
        addMembers(names, type);
      }
    }
  }
  // An extension on SceneController makes `SceneController.member` true too.
  for (final extension in extensions) {
    final target = extension.extendedType.element?.name;
    if (target == null || !members.containsKey(target)) continue;
    addMembers(members[target]!, extension);
  }
  return (types, members);
}

void addMembers(Set<String> names, InstanceElement type) {
  for (final element in [
    ...type.fields,
    ...type.methods,
    ...type.getters,
    ...type.setters,
  ]) {
    final name = element.name;
    if (name != null) names.add(name.replaceAll('=', ''));
  }
}

final codeSpan = RegExp(r'`([^`\n]+)`');
final typeToken = RegExp(r'^[A-Z][A-Za-z0-9]*$');
final memberToken = RegExp(
  r'^([A-Z][A-Za-z0-9]*)\.([A-Za-z_][A-Za-z0-9_]*)(?:\(.*\))?$',
);
final markdownLink = RegExp(r'\]\((/docs[^)\s]*)\)|href="(/docs[^"]*)"');

List<String> proseProblems(
  String page,
  List<String> lines,
  Set<String> types,
  Map<String, Set<String>> members,
) {
  final problems = <String>[];
  var fenced = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    for (final match in codeSpan.allMatches(line)) {
      final token = match[1]!.trim();
      if (proseAllowlist.contains(token)) continue;
      final member = memberToken.firstMatch(token);
      if (member != null) {
        final type = member[1]!;
        final name = member[2]!;
        if (proseAllowlist.contains(type)) continue;
        if (!types.contains(type)) {
          problems.add('$page:${i + 1}: unknown type `$type` in `$token`');
        } else if (members.containsKey(type) &&
            !members[type]!.contains(name)) {
          problems.add('$page:${i + 1}: `$type` has no member `$name`');
        }
        continue;
      }
      if (typeToken.hasMatch(token) &&
          token.contains(RegExp('[a-z]')) &&
          !types.contains(token)) {
        problems.add('$page:${i + 1}: unknown type `$token`');
      }
    }
    for (final match in markdownLink.allMatches(line)) {
      final href = (match[1] ?? match[2])!;
      var slug = href.split('#').first;
      slug = slug.replaceFirst(RegExp(r'^/docs(/zyren)?/?'), '');
      slug = slug.replaceAll(RegExp(r'/$'), '');
      final candidates = slug.isEmpty
          ? ['$docsRoot/index.mdx']
          : ['$docsRoot/$slug.mdx', '$docsRoot/$slug/index.mdx'];
      if (!candidates.any((path) => File(path).existsSync())) {
        problems.add('$page:${i + 1}: broken link $href');
      }
    }
  }
  return problems;
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  if (!Directory(docsRoot).existsSync()) {
    stderr.writeln('No $docsRoot here. Run from the workspace root.');
    exit(2);
  }
  final pages = args.isNotEmpty
      ? args
      : (Directory(docsRoot)
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .where(
              (p) =>
                  p.endsWith('.mdx') && !p.startsWith('$docsRoot/reference/'),
            )
            .toList()
          ..sort());

  final generated = Directory(generatedRoot);
  if (generated.existsSync()) generated.deleteSync(recursive: true);
  generated.createSync(recursive: true);
  try {
    await check(root, pages);
  } finally {
    generated.deleteSync(recursive: true);
  }
}

Future<void> check(String root, List<String> pages) async {
  final units = <Unit>[];
  final pageLines = <String, List<String>>{};
  for (final page in pages) {
    final lines = File(page).readAsLinesSync();
    pageLines[page] = lines;
    final fences = fencesOf(page, lines);
    for (var i = 0; i < fences.length; i++) {
      final unit = buildUnit(fences[i], i);
      File(unit.path).writeAsStringSync(unit.source);
      units.add(unit);
    }
  }
  // An empty anchor file gives the symbol lookup a context even when no page
  // has a fence.
  final anchor = File('$generatedRoot/_anchor.dart')
    ..writeAsStringSync('// Context anchor for symbol lookup.\n');

  final collection = AnalysisContextCollection(
    includedPaths: ['$root/$generatedRoot'],
  );
  final problems = <String>[];
  try {
    for (final unit in units) {
      final path = '$root/${unit.path}';
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      if (result is! ErrorsResult) {
        problems.add('${unit.fence.page}:${unit.fence.line}: cannot analyze');
        continue;
      }
      for (final diagnostic in result.diagnostics) {
        if (diagnostic.severity == Severity.info) continue;
        final code = diagnostic.diagnosticCode.lowerCaseName;
        if (ignoredCodes.contains(code)) continue;
        final generatedLine = result.lineInfo
            .getLocation(diagnostic.offset)
            .lineNumber;
        final pageLine = unit.lineMap[generatedLine];
        final where = pageLine == null
            ? '${unit.fence.page}:${unit.fence.line} (prelude or wrapper, see ${unit.path}:$generatedLine)'
            : '${unit.fence.page}:$pageLine';
        problems.add('$where: $code: ${diagnostic.message}');
      }
    }
    final (types, members) = await knownSymbols(
      collection,
      '$root/${anchor.path}',
    );
    for (final entry in pageLines.entries) {
      problems.addAll(proseProblems(entry.key, entry.value, types, members));
    }
  } finally {
    await collection.dispose();
  }

  stdout.writeln(
    'Checked ${pages.length} pages and ${units.length} Dart samples.',
  );
  if (problems.isEmpty) {
    stdout.writeln('No problems found.');
    return;
  }
  problems.forEach(stdout.writeln);
  stdout.writeln('${problems.length} problems.');
  exitCode = 1;
}
