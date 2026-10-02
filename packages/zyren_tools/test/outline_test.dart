import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'outlines follow selection without replacing materials and restore ownership',
    () async {
      final scene = Scene();
      final a = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final b = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final material = a.material;
      final previous = SceneOutline(objects: [b]);
      scene.outline = previous;
      final tools = SceneToolsPlugin(highlightSelection: false);
      final outlines = SceneOutlinePlugin();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => _Renderer(),
        plugins: [tools, outlines],
      );
      try {
        tools.select(a);
        await flush();
        expect(outlines.isActive, isTrue);
        expect(scene.outline!.objects, contains(a));
        expect(a.material, same(material));
        tools.select(b);
        await flush();
        tools.select(null);
        await flush();
        expect(scene.outline, same(previous));
        tools.select(a);
        await flush();
        final external = SceneOutline(objects: [b], width: 5);
        scene.outline = external;
        tools.clearHistory();
        await flush();
        expect(outlines.isActive, isFalse);
        expect(scene.outline, same(external));
        tools.select(b);
        await flush();
        expect(outlines.isActive, isTrue);
        tools.select(null);
        await flush();
        expect(scene.outline, same(external));
        tools.select(a);
        await flush();
        await engine.dispose();
        expect(scene.outline, same(external));
      } finally {
        await engine.dispose();
      }
    },
  );

  test(
    'removed selections clear and detach preserves an external edit',
    () async {
      final scene = Scene();
      final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final tools = SceneToolsPlugin(highlightSelection: false);
      final outlines = SceneOutlinePlugin();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => _Renderer(),
        plugins: [tools, outlines],
      );
      tools.select(mesh);
      await flush();
      scene.remove(mesh);
      await flush();
      expect(scene.outline, isNull);
      scene.add(mesh);
      tools.select(mesh);
      await flush();
      final external = SceneOutline(objects: [mesh], width: 4);
      scene.outline = external;
      await engine.dispose();
      expect(scene.outline, same(external));
    },
  );

  test('unsupported renderers reject outline attachment', () async {
    await expectLater(
      SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [SceneToolsPlugin(), SceneOutlinePlugin()],
      ),
      throwsA(isA<SceneException>()),
    );
  });
}

class _Renderer extends TestRenderer {
  _Renderer() : super([]);
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'outline test',
    features: {
      RenderFeature.indexedMeshes,
      RenderFeature.rgbaReadback,
      RenderFeature.selectionOutlines,
    },
    maxDimension: 64,
  );
}
