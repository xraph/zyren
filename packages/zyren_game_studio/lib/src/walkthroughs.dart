part of '../ai.dart';

final class GameAiWalkthroughs {
  final start = GlobalKey(),
      play = GlobalKey(),
      perception = GlobalKey(),
      training = GlobalKey();
  final Map<String, Future<void> Function()> prepare = {};
  Map<String, List<WalkthroughStep>> get registrations => {
    'studio.game.start': [
      _step(
        'studio.game.start',
        start,
        'Game authoring',
        'Choose a template and edit its saved game components.',
      ),
    ],
    'studio.game.play': [
      _step(
        'studio.game.play',
        play,
        'Play isolation',
        'Compile a frozen edit revision. Stop drains the play session before you edit again.',
      ),
    ],
    'studio.ai.perception': [
      _step(
        'studio.ai.perception',
        perception,
        'NPC knowledge',
        'Compare semantic queries with the NPC camera. Historical memory keeps its captured coordinate frame.',
      ),
    ],
    'studio.ai.train': [
      _step(
        'studio.ai.train',
        training,
        'Local training',
        'Configure a prepared worker and project paths. Runs show verified process receipts. Import and activation are separate.',
      ),
    ],
  };
  WalkthroughStep _step(
    String id,
    GlobalKey anchor,
    String title,
    String message,
  ) => WalkthroughStep(
    anchor: anchor,
    title: title,
    message: message,
    prepare: prepare[id],
  );
}

Widget _tourButton(BuildContext context, String id, String label) {
  final provider = context
      .dependOnInheritedWidgetOfExactType<OnboardingProvider>();
  if (provider == null || !provider.walkthroughs.containsKey(id)) {
    return const SizedBox.shrink();
  }
  return TextButton(
    onPressed: () => provider.start(context, id),
    child: Text(label),
  );
}
