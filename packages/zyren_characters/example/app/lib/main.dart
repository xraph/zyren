import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'character_lab_scene.dart';
import 'lab_agents.dart';
import 'package:zyren_agents/zyren_agents.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: const _LoadLab(),
    ),
  );
}

SceneController createLabController(
  CharacterLabScene lab, {
  AgentRegistry? registry,
}) {
  final controller = SceneController(
    scene: lab.scene,
    camera: PerspectiveCamera(
      position: const Vec3(8, 7, 9),
      target: const Vec3(3, .5, 3),
    ),
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  );
  for (final plugin in lab.plugins) {
    controller.use(plugin);
  }
  if (registry != null) {
    controller.use(CharacterLabAgents(lab, registry, recordPresentation: true));
  }
  return controller;
}

class _LoadLab extends StatefulWidget {
  const _LoadLab();
  @override
  State<_LoadLab> createState() => _LoadLabState();
}

class _LoadLabState extends State<_LoadLab> {
  CharacterLabScene? lab;
  SceneController? controller;
  Object? error;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final value = await CharacterLabScene.load();
      if (!mounted) {
        await value.close();
        return;
      }
      setState(() {
        lab = value;
        controller = createLabController(
          value,
          registry: AgentRegistry(
            grantedScopes: {
              'characters.playback',
              'characters.locomotion',
              'navigation.edit',
            },
          ),
        );
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  void dispose() {
    final c = controller, l = lab;
    if (c != null) {
      c.dispose();
      unawaited(c.whenDisposed.then((_) => l!.close()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => controller == null
      ? Scaffold(
          body: SafeArea(
            child: error == null
                ? const Center(child: CircularProgressIndicator())
                : ZeroState(
                    title: 'Character scene failed',
                    message: '$error',
                    actionLabel: 'Retry',
                    onAction: () {
                      setState(() => error = null);
                      unawaited(load());
                    },
                  ),
          ),
        )
      : CharacterLabView(lab: lab!, controller: controller!);
}

class CharacterLabView extends StatefulWidget {
  final CharacterLabScene lab;
  final SceneController controller;
  const CharacterLabView({
    super.key,
    required this.lab,
    required this.controller,
  });
  @override
  State<CharacterLabView> createState() => _CharacterLabViewState();
}

class _CharacterLabViewState extends State<CharacterLabView> {
  StreamSubscription<FrameStats>? subscription;
  int frames = 0;
  @override
  void initState() {
    super.initState();
    subscription = widget.controller.frameStats.listen((_) {
      frames++;
      if (frames % 10 == 0 && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lab = widget.lab;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    'Character Lab',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    lab.removed
                        ? 'Character removed'
                        : '${lab.character.isAttached ? lab.character.currentState : "Loading"} · ${lab.steps} steps · ${lab.follower.replans} routes',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                runSpacing: 0,
                children: [
                  TextButton(
                    key: const Key('pause'),
                    onPressed: lab.character.isAttached && !lab.removed
                        ? () =>
                              setState(() => lab.setPaused(!lab.physics.paused))
                        : null,
                    child: Text(lab.physics.paused ? 'Resume' : 'Pause'),
                  ),
                  FilterChip(
                    label: const Text('Obstacle'),
                    selected: lab.obstacle,
                    onSelected: (v) => setState(() => lab.setObstacle(v)),
                  ),
                  FilterChip(
                    label: const Text('Foot IK'),
                    selected: lab.ikEnabled,
                    onSelected: (v) => setState(() => lab.ikEnabled = v),
                  ),
                  FilterChip(
                    label: const Text('Retarget'),
                    selected: lab.retargetEnabled,
                    onSelected: (v) => setState(() => lab.retargetEnabled = v),
                  ),
                  TextButton(
                    key: const Key('return'),
                    onPressed: lab.character.isAttached && !lab.removed
                        ? () => setState(() => lab.setGoal(const Vec3(1, 0, 1)))
                        : null,
                    child: const Text('Return'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  lab.viewport = ViewportMetrics(
                    constraints.maxWidth,
                    constraints.maxHeight,
                    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  );
                  return SceneView(controller: widget.controller);
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Root motion + capsule collision · Generated navigation · Longer-leg retarget',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
