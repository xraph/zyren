import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() => runApp(const ParticleLab());

class ParticleLab extends StatelessWidget {
  const ParticleLab({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const ParticleWorkbench(),
  );
}

class ParticleWorkbench extends StatefulWidget {
  const ParticleWorkbench({super.key});
  @override
  State<ParticleWorkbench> createState() => ParticleWorkbenchState();
}

class ParticleWorkbenchState extends State<ParticleWorkbench> {
  late final SceneController viewport;
  late final ParticlePlugin particles;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? frameStats;
  String selected = 'Sparks';
  String? error;
  bool ready = false, busy = false;
  int? inspectedCount;
  double intensity = 1;
  @override
  void initState() {
    super.initState();
    final scene = Scene()..background = const Color3(.015, .02, .035);
    final camera = PerspectiveCamera(
      position: const Vec3(0, 2, 7),
      near: .05,
      far: 100,
    );
    scene.add(
        Mesh(
          PlaneGeometry(width: 12, height: 12),
          UnlitMaterial(color: const Color3(.035, .05, .075)),
        ),
      )
      ..rotateX(-math.pi / 2)
      ..position = const Vec3(0, -1, 0);
    viewport = SceneController(
      scene: scene,
      camera: camera,
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : (Platform.isMacOS || Platform.isIOS)
          ? const SceneRuntime.nativeMetal()
          : const SceneRuntime(),
      options: EngineOptions(
        presentation: (Platform.isMacOS || Platform.isIOS || Platform.isAndroid)
            ? PresentationPolicy.requireNative
            : PresentationPolicy.allowReadback,
        recovery: RecoveryPolicy.automaticOnce,
      ),
    );
    particles = viewport.use(
      ParticlePlugin(
        emitters: [
          ParticleEmitter(
            name: 'Sparks',
            settings: ParticleSettings(
              capacity: 4096,
              rate: 500,
              lifetime: 1.5,
              shape: ConeParticleShape(radius: .12, height: .08),
              velocity: const Vec3(0, 3, 0),
              velocitySpread: const Vec3(2, 1, 2),
              appearance: ParticleAppearance.stretched,
              blend: ParticleBlend.additive,
              stretch: .25,
              drag: .5,
              color: ParticleGradient(
                red: ParticleCurve.constant(1),
                green: ParticleCurve([CurveKey(0, .8), CurveKey(1, .1)]),
                blue: ParticleCurve.constant(.05),
                alpha: ParticleCurve([CurveKey(0, 1), CurveKey(1, 0)]),
              ),
              size: ParticleCurve([CurveKey(0, .07), CurveKey(1, .02)]),
              collisions: [
                ParticlePlane(
                  normal: const Vec3(0, 1, 0),
                  offset: 1,
                  restitution: .5,
                ),
              ],
            ),
          ),
          ParticleEmitter(
            name: 'Sprites',
            autoStart: false,
            settings: ParticleSettings(
              capacity: 1024,
              rate: 80,
              lifetime: 3,
              gravity: const Vec3(0, .2, 0),
              shape: BoxParticleShape(halfExtent: const Vec3(.6, .05, .6)),
              velocity: const Vec3(0, .6, 0),
              velocitySpread: const Vec3(.2, .2, .2),
              texture: _spriteAtlas(),
              size: ParticleCurve([CurveKey(0, .15), CurveKey(1, .6)]),
              color: ParticleGradient(
                red: ParticleCurve.constant(.3),
                green: ParticleCurve.constant(.7),
                blue: ParticleCurve.constant(1),
                alpha: ParticleCurve([
                  CurveKey(0, 0),
                  CurveKey(.1, .7),
                  CurveKey(1, 0),
                ]),
              ),
            ),
          ),
          ParticleEmitter(
            name: 'Trails',
            autoStart: false,
            settings: ParticleSettings(
              capacity: 256,
              rate: 25,
              lifetime: 3,
              gravity: Vec3.zero,
              shape: SphereParticleShape(radius: .2),
              velocitySpread: const Vec3(1.2, 1.2, 1.2),
              forces: [FlowParticleForce(amplitude: 2, frequency: 2)],
              trails: TrailSettings(samples: 32, width: .4),
              blend: ParticleBlend.additive,
              size: ParticleCurve.constant(.1),
              color: ParticleGradient.solid(
                const Color3(.1, .7, 1),
                opacity: .6,
              ),
            ),
          ),
          ParticleEmitter(
            name: 'Flow',
            autoStart: false,
            settings: ParticleSettings(
              capacity: 2048,
              rate: 250,
              lifetime: 6,
              shape: BoxParticleShape(halfExtent: const Vec3(1, .4, .4)),
              gravity: Vec3.zero,
              drag: 1,
              velocity: const Vec3(.5, 0, 0),
              forces: [
                FlowParticleForce(amplitude: 2, frequency: 1.5, speed: .5),
              ],
              trails: TrailSettings(samples: 16, width: .5),
              blend: ParticleBlend.additive,
              size: ParticleCurve.constant(.045),
              color: ParticleGradient.solid(
                const Color3(.2, 1, .4),
                opacity: .4,
              ),
            ),
          ),
          ParticleEmitter(
            name: 'Meshes',
            autoStart: false,
            settings: ParticleSettings(
              capacity: 256,
              rate: 20,
              lifetime: 3,
              appearance: ParticleAppearance.mesh,
              mesh: _meshData(),
              gravity: const Vec3(0, -.3, 0),
              velocity: const Vec3(0, 1, 0),
              velocitySpread: const Vec3(.6, .3, .6),
              size: ParticleCurve.constant(.12),
              rotation: ParticleCurve([CurveKey(0, 0), CurveKey(1, 8)]),
              color: ParticleGradient.solid(const Color3(.6, .3, 1)),
            ),
          ),
        ],
      ),
    );
    viewport.use(
      OrbitControlsPlugin(
        configure: (controls) {
          controls.target = const Vec3(0, .6, 0);
        },
      ),
    );
    viewport.ready.then(
      (_) {
        if (mounted) setState(() => ready = true);
      },
      onError: (Object e) {
        if (mounted) setState(() => error = e.toString());
      },
    );
    subscription = viewport.frameStats.listen((stats) {
      if (mounted) setState(() => frameStats = stats);
    });
  }

  Future<void> action(Future<void> Function() operation) async {
    setState(() => busy = true);
    try {
      await operation();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> select(String name) async {
    await particles.controller.stop(selected, clear: true);
    selected = name;
    inspectedCount = null;
    await particles.controller.start(name);
  }

  @override
  void dispose() {
    subscription?.cancel();
    viewport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = ready && !particles.controller.isClosed;
    final controlsEnabled = available && !busy;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Zyren particles',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  for (final name in [
                    'Sparks',
                    'Sprites',
                    'Trails',
                    'Flow',
                    'Meshes',
                  ])
                    ChoiceChip(
                      label: Text(name),
                      selected: selected == name,
                      onSelected: controlsEnabled
                          ? (_) => action(() => select(name))
                          : null,
                    ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () =>
                              action(() => particles.controller.start(selected))
                        : null,
                    child: const Text('Play'),
                  ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () => action(() async {
                            if (particles.controller.playback(selected) ==
                                ParticlePlayback.paused) {
                              await particles.controller.resume(selected);
                            } else {
                              await particles.controller.pause(selected);
                            }
                          })
                        : null,
                    child: Text(
                      available &&
                              particles.controller.playback(selected) ==
                                  ParticlePlayback.paused
                          ? 'Resume'
                          : 'Pause',
                    ),
                  ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () =>
                              action(() => particles.controller.stop(selected))
                        : null,
                    child: const Text('Drain'),
                  ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () =>
                              action(() => particles.controller.reset(selected))
                        : null,
                    child: const Text('Reset'),
                  ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () => action(
                            () => particles.controller.burst(
                              selected,
                              (100 * intensity).round(),
                            ),
                          )
                        : null,
                    child: const Text('Burst'),
                  ),
                  SizedBox(
                    width: 160,
                    child: Slider(
                      value: intensity,
                      min: .1,
                      max: 2,
                      divisions: 19,
                      onChanged: controlsEnabled
                          ? (v) => setState(() => intensity = v)
                          : null,
                      label: '${(100 * intensity).round()} burst particles',
                    ),
                  ),
                  TextButton(
                    onPressed: controlsEnabled
                        ? () => action(() async {
                            final values = await particles.controller.inspect(
                              selected,
                            );
                            if (mounted) {
                              setState(() => inspectedCount = values.length);
                            }
                          })
                        : null,
                    child: const Text('Inspect count'),
                  ),
                ],
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.orange),
                      ),
                    ),
                    TextButton(
                      onPressed: () => action(() => viewport.retry()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Semantics(
                container: true,
                label:
                    'Native particle viewport. Drag to orbit and scroll to zoom.',
                image: true,
                child: SceneView(controller: viewport),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(
                    Platform.isMacOS || Platform.isIOS
                        ? 'Metal native view'
                        : Platform.isAndroid
                        ? 'Vulkan native surface'
                        : 'Native renderer, image presentation',
                  ),
                  if (available)
                    Text(
                      '${particles.controller.measurements(selected).dispatches} dispatches/frame',
                    ),
                  if (available)
                    Text(
                      '${particles.controller.measurements(selected).uploadedBytes} bytes uploaded/frame',
                    ),
                  if (available)
                    Text(
                      '${particles.controller.measurements(selected).hostTime.inMicroseconds} μs host work',
                    ),
                  if (inspectedCount != null)
                    Text('$inspectedCount particles at last inspection'),
                  if (frameStats != null)
                    Text('${frameStats!.drawCalls} draw calls'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

GeometryData _meshData() {
  final box = BoxGeometry();
  return GeometryData(attributes: box.attributes, indices: box.indices);
}

ParticleTexture _spriteAtlas() {
  const tile = 32, columns = 4;
  final pixels = Uint8List(tile * tile * columns * 4);
  for (var frame = 0; frame < columns; frame++) {
    for (var y = 0; y < tile; y++) {
      for (var x = 0; x < tile; x++) {
        final dx = (x + .5) / tile - .5, dy = (y + .5) / tile - .5;
        final alpha = math.max(0, 1 - math.sqrt(dx * dx + dy * dy) * 2);
        final i = (y * tile * columns + frame * tile + x) * 4;
        pixels[i] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
        pixels[i + 3] = (alpha * alpha * 255 * (.4 + .2 * frame)).round();
      }
    }
  }
  return ParticleTexture(
    width: tile * columns,
    height: tile,
    rgba: pixels,
    columns: columns,
    framesPerSecond: 8,
  );
}
