import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'support/fakes.dart';

class _Validator extends TestPlugin {
  final void Function(List<ScenePlugin>) validate;
  _Validator(super.id, super.events, this.validate, {super.dependencies});

  @override
  void validateComposition(List<ScenePlugin> plugins) => validate(plugins);
}

void main() {
  test('validates a resolved immutable list before allocating', () async {
    final events = <String>[];
    final seen = <List<ScenePlugin>>[];
    final a = _Validator('a', events, (plugins) {
      expect(plugins.map((p) => p.id), ['b', 'a']);
      expect(() => plugins.clear(), throwsUnsupportedError);
      seen.add(plugins);
    }, dependencies: {'b'});
    final b = _Validator('b', events, seen.add);
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      plugins: [a, b],
      rendererFactory: () async {
        expect(seen, hasLength(2));
        expect(seen.first, same(seen.last));
        return TestRenderer(events);
      },
    );
    await engine.dispose();
  });

  test('invalid live composition leaves old attachments untouched', () async {
    final events = <String>[];
    final stable = TestPlugin('stable', events);
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      plugins: [stable],
      rendererFactory: () async => TestRenderer(events),
    );
    events.clear();
    final bad = _Validator('bad', events, (_) => throw StateError('invalid'));
    await expectLater(engine.updatePlugins([bad]), throwsStateError);
    expect(engine.pluginIds, ['stable']);
    expect(events, isEmpty);
    await engine.dispose();
  });
}
