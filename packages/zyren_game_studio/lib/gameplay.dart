/// Studio compatibility bindings over the shared native gameplay runtime.
library;

import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/gameplay.dart';
import 'play.dart';

export 'package:zyren_game_native/gameplay.dart'
    show GameLevelGameplay, GameEventJournal;

final class GamePlayGameplay extends GameLevelGameplay {
  GamePlayGameplay(GamePlaySession play, GameRuleLibrary library)
    : super(
        play.levelRuntime ??
            (throw StateError('Play runtime is not initialized.')),
        library,
      );
}

typedef GamePlayEventJournal = GameEventJournal;
