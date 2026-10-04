import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/ai_authoring.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'saved AI model pins are opaque resources with bounded exact identity',
    () {
      final authoring = createGameAiDevelopmentAuthoring();
      var document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'models').document;
      final hash = 'a' * 64;
      final pin = {
        'schemaVersion': 1,
        'bundleVersion': 'b' * 64,
        'sourceId': 'model.$hash.actor.onnx',
        'sourceRevision': hash,
        'sha256': hash,
        'uri': 'model:///$hash/actor.onnx',
      };
      document = authoring.addComponent(
        document,
        'player',
        GameComponentRecord('game.ai', 1, {
          'profile': 'guard',
          'brain': 'hybrid',
          'modelHash': hash,
          'modelReference': pin,
        }),
      );
      final reopened = StudioDocument.decode(document.encode());
      expect(reopened.assets, isEmpty);
      expect(
        gameAiModelReferences(authoring, reopened)[hash]!.bundleVersion,
        'b' * 64,
      );
      final broken = authoring.setField(
        reopened,
        nodeId: 'player',
        component: 'game.ai',
        field: 'modelReference',
        value: {...pin, 'sha256': 'c' * 64},
      );
      expect(() => gameAiModelReferences(authoring, broken), throwsStateError);
      final scripted = authoring.setField(
        reopened,
        nodeId: 'player',
        component: 'game.ai',
        field: 'brain',
        value: 'scripted',
      );
      expect(gameAiModelReferences(authoring, scripted), isEmpty);
      expect(
        gameAiModelReferences(authoring, scripted, includeScripted: true),
        hasLength(1),
      );
    },
  );
}
