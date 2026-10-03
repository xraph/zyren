import 'dart:io';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

Future<void> main(List<String> args) async {
  final bundle = PipelineBundle.decode(await File(args[1]).readAsBytes());
  final cache = FilePipelineCache(directory: Directory(args[0]), maxBundles: 1);
  for (var i = 0; i < 5; i++) {
    await cache.put(bundle);
  }
}
