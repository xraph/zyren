import 'dart:convert';
import 'dart:io';
import 'package:zyren_game_lab/benchmark.dart';

void main() => stdout.writeln(
  const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'profiles': {
      for (final p in gameBenchmarkProfiles.values) p.id: p.toJson(),
    },
  }),
);
