import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import '../example/inspection_recipe.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test('documented recipe attaches, renders and reports its cube', () async {
    final recipe = inspectionRecipe();
    final engine = await SceneEngine.create(
      scene: recipe.scene,
      camera: recipe.camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [recipe.inspector],
    );
    addTearDown(engine.dispose);
    await engine.render(elapsed: Duration.zero, width: 16, height: 16);
    final report = recipe.diagnostics.call('export_report');
    final nodes = (report['scene'] as Map)['nodes'] as List;
    expect(nodes.single['name'], 'Cube');
    expect(nodes.single['triangles'], 12);
    expect((report['frameStats'] as Map)['sampleCount'], 1);
    expect(
      ((report['diagnosis'] as Map)['findings'] as List).map((e) => e['code']),
      isNot(contains('outsideClipVolume')),
    );
  });
}
