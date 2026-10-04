import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'runtime_test.dart' as fixture;

void main() {
  test(
    'sleeping checkpoint with nonzero motion rejects before native or identity mutation',
    () async {
      final scene = Scene(), camera = PerspectiveCamera();
      final runtime = GameLevelRuntime(
        project: fixture.project(),
        scene: scene,
        camera: camera,
        objects: fixture.objects(scene),
      );
      SceneEngine? engine;
      try {
        await runtime.initialize();
        engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => fixture.RuntimeRenderer(),
          plugins: runtime.plugins,
        );
        runtime.simulation!.step();
        runtime.pause();
        final before = runtime.save(), actor = runtime.inputActor!;
        final data = jsonDecode(before.encode()) as Map<String, Object?>;
        final state = data['state'] as Map;
        final bodies = (state['game.native-level'] as Map)['bodies'] as Map;
        final player = bodies['player'] as Map;
        player['sleeping'] = true;
        player['velocity'] = [1, 0, 0];
        player['position'] = [100, 100, 100];
        final malformed = GameSave.decode(jsonEncode(data));
        expect(() => runtime.restore(malformed), throwsFormatException);
        expect(runtime.inputActor, actor);
        expect(runtime.resolveBody(actor), isNotNull);
        expect(runtime.error, isNull);
        expect(runtime.save().encode(), before.encode());
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );
}
