import 'dart:io';

import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'triangle_source.dart';

Future<void> main() async {
  final source = TriangleSource();
  final bundle = await PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
  final issues = await bundle.validateGltf();
  final temporary = await Directory.systemTemp.createTemp('zyren-pipeline-');
  try {
    final archive = File('${temporary.path}/triangle.zybundle');
    await archive.writeAsBytes(bundle.encode());
    final offline = PipelineBundle.decode(await archive.readAsBytes());
    final scope = offline.open();
    try {
      final model = await scope.load(offline.gltfRequest()).result;
      final instance = model.instantiate();
      print('Bundle ${offline.version}');
      print(
        '${offline.resources.length} sources, ${offline.byteLength} original bytes',
      );
      print(
        '${instance.children.length} scene roots, ${issues.length} validation warnings',
      );
    } finally {
      await scope.close();
    }
  } finally {
    await temporary.delete(recursive: true);
  }
}
