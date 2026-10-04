import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart' show ZeroState;
import 'package:flutter_zyren_game/flutter_zyren_game.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'game_session.dart';
import 'native_platform.dart';

void main() => runApp(const GameLabApp());

class GameLabApp extends StatelessWidget {
  final Future<GameLabRun> Function(String game)? loadGame;
  const GameLabApp({super.key, this.loadGame});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zyren Game Lab',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff51c1b5),
        brightness: Brightness.dark,
      ),
      visualDensity: VisualDensity.compact,
      useMaterial3: true,
    ),
    home: GameLabScreen(loadGame: loadGame),
  );
}

class GameLabScreen extends StatefulWidget {
  final Future<GameLabRun> Function(String game)? loadGame;
  const GameLabScreen({super.key, this.loadGame});
  @override
  State<GameLabScreen> createState() => _GameLabScreenState();
}

class _GameLabScreenState extends State<GameLabScreen> {
  String selected = 'exploration';
  GameLabRun? game;
  Object? error;
  bool busy = false, checkpointBusy = false;
  GameSave? checkpoint;
  int generation = 0;
  Future<void> open() async {
    if (busy || checkpointBusy) return;
    final epoch = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    final old = game;
    if (old != null) old.removeListener(_changed);
    setState(() {
      game = null;
      checkpoint = null;
    });
    try {
      await old?.close();
      final next = await (widget.loadGame ?? _loadGame)(selected);
      if (!mounted || epoch != generation) {
        await next.close();
        return;
      }
      next.addListener(_changed);
      setState(() => game = next);
    } catch (e, stack) {
      if (mounted && epoch == generation) {
        setState(() => error = e);
      } else {
        _reportCleanup(e, stack);
      }
    } finally {
      if (mounted && epoch == generation) setState(() => busy = false);
    }
  }

  Future<void> saveOrRestore({required bool restore}) async {
    final current = game;
    final saved = checkpoint;
    if (busy ||
        checkpointBusy ||
        current?.ai == null ||
        (restore && saved == null)) {
      return;
    }
    setState(() => checkpointBusy = true);
    try {
      if (restore) {
        await current!.ai!.restore(saved!);
      } else {
        final next = await current!.ai!.save();
        if (mounted && identical(game, current)) {
          setState(() => checkpoint = next);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Checkpoint failed: $e')));
      }
    } finally {
      if (mounted) setState(() => checkpointBusy = false);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    generation++;
    final old = game;
    old?.removeListener(_changed);
    if (old != null) unawaited(old.close().catchError(_reportCleanup));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = game;
    final failure = error ?? active?.error ?? active?.runtime.error;
    return Scaffold(
      appBar: AppBar(title: const Text('Zyren Game Lab'), toolbarHeight: 48),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue: selected,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Game',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'exploration',
                        child: Text('Exploration'),
                      ),
                      DropdownMenuItem(
                        value: 'vehiclePlayground',
                        child: Text('Vehicle playground'),
                      ),
                    ],
                    onChanged: busy || checkpointBusy
                        ? null
                        : (value) => setState(() => selected = value!),
                  ),
                ),
                FilledButton(
                  onPressed: busy || checkpointBusy ? null : open,
                  child: Text(active == null ? 'Play' : 'Restart'),
                ),
                if (active != null && failure == null) ...[
                  TextButton(
                    onPressed: checkpointBusy ? null : active.togglePause,
                    child: Text(active.session.paused ? 'Resume' : 'Pause'),
                  ),
                  if (active.session.paused)
                    TextButton(
                      onPressed: checkpointBusy ? null : active.step,
                      child: const Text('Step'),
                    ),
                  if (active.ai != null) ...[
                    TextButton(
                      onPressed: checkpointBusy
                          ? null
                          : () => saveOrRestore(restore: false),
                      child: const Text('Save'),
                    ),
                    if (checkpoint != null)
                      TextButton(
                        onPressed: checkpointBusy
                            ? null
                            : () => saveOrRestore(restore: true),
                        child: const Text('Restore'),
                      ),
                  ],
                  Text('Tick ${active.session.tick}'),
                ],
              ],
            ),
          ),
          Expanded(
            child: busy
                ? const Center(child: CircularProgressIndicator())
                : failure != null
                ? ZeroState(
                    title: 'Game could not continue',
                    message: '$failure',
                    actionLabel: 'Retry',
                    onAction: open,
                  )
                : active == null
                ? ZeroState(
                    title: 'Choose a reference game',
                    message:
                        'Collect the key, open the gate and reach the checkpoint. The vehicle playground also lets you drive the buggy.',
                    actionLabel: 'Play selected game',
                    onAction: open,
                  )
                : GameSceneBinding(
                    controller: active.controller,
                    session: active.session,
                    actions: active.actions,
                    autofocus: true,
                    enableGamepads: true,
                    onGamepadError: (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Gamepad unavailable: $e')),
                        );
                      }
                    },
                    hud: _Hud(game: active),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  final GameLabRun game;
  const _Hud({required this.game});
  @override
  Widget build(BuildContext context) {
    final actor = game.runtime.inputActor;
    final candidates = actor == null
        ? const []
        : game.gameplay.available(actor);
    final controlled = game.runtime.controlledActor;
    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            left: 12,
            right: 12,
            top: 8,
            child: IgnorePointer(
              child: Material(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: .88),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      const Text('WASD move · Space jump · E interact / exit'),
                      if (actor != null)
                        for (final id in ['key', 'gate', 'checkpoint'])
                          Text(
                            '$id: ${game.gameplay.authored.objectiveComplete(actor, id) ? 'complete' : 'pending'}',
                          ),
                      if (controlled != null && controlled != actor)
                        const Text('Driving'),
                      if (game.ai case final ai?)
                        Text(
                          'NPCs ${ai.actors.length} · learned decisions ${ai.completedDecisions} · fallback ticks ${ai.fallbackTicks}',
                        ),
                      if (candidates.isNotEmpty)
                        Text('E: ${candidates.first.label}'),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (actor != null) ...[
            Positioned(
              left: 12,
              bottom: 12,
              child: GameAxisPad(
                actions: game.actions,
                xAction: 'move.x',
                yAction: 'move.z',
                label: 'Move',
                extent: 96,
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: Wrap(
                spacing: 8,
                children: [
                  GameActionButton(
                    actions: game.actions,
                    action: 'jump',
                    label: 'Jump',
                  ),
                  GameActionButton(
                    actions: game.actions,
                    action: 'interact',
                    label: 'Interact',
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<GameLabRun> _loadGame(String id) async {
  final bytes = await rootBundle.load('games/$id.zygame');
  return GameLabSession.load(
    bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    rendering: gameLabRendering(),
  );
}

void _reportCleanup(Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'Zyren Game Lab',
      context: ErrorDescription('while releasing a closed game screen'),
    ),
  );
}
