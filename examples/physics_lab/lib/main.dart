import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart' hide BoxShape;
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() => runApp(const PhysicsLabApp());

class PhysicsLabApp extends StatelessWidget {
  const PhysicsLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const PhysicsLab(),
  );
}

class PhysicsLab extends StatefulWidget {
  const PhysicsLab({super.key});
  @override
  State<PhysicsLab> createState() => PhysicsLabState();
}

class PhysicsLabState extends State<PhysicsLab> {
  final world = PhysicsWorld();
  final scene = Scene()..background = const Color3(.06, .08, .11);
  late final PhysicsPlugin physics;
  late final SceneController controller;
  late PhysicsBody mover;
  late PhysicsSnapshot initial;
  final initialObjects = <Object3D, (int, BodyKind)>{};
  final spawned = <Object3D>[];
  int collisions = 0, sensors = 0;
  double target = 0;
  String query = 'Cast a ray or test overlaps.';
  Timer? timer;
  @override
  void initState() {
    super.initState();
    physics = PhysicsPlugin(
      world: world,
      debug: true,
      onEvents: (events) {
        for (final e in events) {
          if (e.kind == 'collision') {
            collisions++;
            if (e.sensor) sensors++;
          }
        }
      },
    );
    _box(
      const Vec3(0, -.5, 0),
      const Vec3(12, 1, 10),
      BodyKind.fixed,
      const Color3(.25, .29, .34),
    );
    _box(
      const Vec3(-2, 4, 0),
      const Vec3(1, 1, 1),
      BodyKind.dynamic,
      const Color3(.9, .45, .18),
    );
    final anchor = _box(
      const Vec3(2, 4, 0),
      const Vec3(.3, .3, .3),
      BodyKind.fixed,
      const Color3(.7, .7, .7),
    );
    final arm = _box(
      const Vec3(2, 2.5, 0),
      const Vec3(.4, 3, .4),
      BodyKind.dynamic,
      const Color3(.2, .65, .9),
    );
    world.createJoint(
      body1: anchor,
      body2: arm,
      kind: JointKind.hinge,
      axis: const Vec3(0, 0, 1),
      anchor2: const Vec3(0, 1.5, 0),
      limits: [-.9, .9],
      motorVelocity: .5,
      maxForce: 2,
    );
    mover = _box(
      const Vec3(0, .4, 2),
      const Vec3(1.4, .8, 1.4),
      BodyKind.kinematicPosition,
      const Color3(.3, .75, .4),
    );
    final sensor = world.createBody(
      kind: BodyKind.fixed,
      pose: PhysicsPose(position: const Vec3(-2, 1.5, 0)),
    );
    sensor.addCollider(const BoxShape(Vec3(1, .3, 1)), sensor: true);
    initial = world.snapshot();
    final camera = PerspectiveCamera(position: const Vec3(9, 7, 12))
      ..lookAt(const Vec3(0, 1.5, 0));
    controller = SceneController(
      scene: scene,
      camera: camera,
      runtime: Platform.isMacOS || Platform.isIOS
          ? const SceneRuntime.nativeMetal()
          : Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime(),
      options: EngineOptions(
        presentation: Platform.isMacOS || Platform.isIOS || Platform.isAndroid
            ? PresentationPolicy.requireNative
            : PresentationPolicy.readbackOnly,
      ),
    );
    controller.use(physics);
    controller.use(OrbitControlsPlugin());
    timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  PhysicsBody _box(Vec3 position, Vec3 size, BodyKind kind, Color3 color) {
    final body = world.createBody(
      kind: kind,
      pose: PhysicsPose(position: position),
      ccd: kind == BodyKind.dynamic,
    );
    body.addCollider(BoxShape(size * .5), friction: .7);
    final mesh = scene.add(
      Mesh(
        BoxGeometry(width: size.x, height: size.y, depth: size.z),
        DiffuseMaterial(color: color),
      ),
    );
    physics.bind(mesh, body);
    initialObjects[mesh] = (body.id, kind);
    return body;
  }

  void spawn() {
    if (spawned.length >= 128) {
      setState(() => query = 'Spawn limit reached. Reset to clear bodies.');
      return;
    }
    final body = world.createBody(
      pose: PhysicsPose(
        position: Vec3(
          -2 + spawned.length % 4,
          5 + (spawned.length % 3).toDouble(),
          -.5,
        ),
      ),
      ccd: true,
    );
    body.addCollider(const SphereShape(.35), restitution: .35);
    final mesh = scene.add(
      Mesh(
        SphereGeometry(radius: .35),
        DiffuseMaterial(color: const Color3(.85, .6, .2)),
      ),
    );
    physics.bind(mesh, body);
    spawned.add(mesh);
  }

  void reset() {
    physics.clearBindings();
    for (final mesh in spawned) {
      scene.remove(mesh);
    }
    spawned.clear();
    world.restore(initial);
    for (final entry in initialObjects.entries) {
      final body = world.body(entry.value.$1, entry.value.$2);
      physics.bind(entry.key, body);
      if (body.kind == BodyKind.kinematicPosition) mover = body;
    }
    collisions = 0;
    sensors = 0;
    target = 0;
    controller.invalidate();
    setState(() => query = 'Snapshot restored.');
  }

  @override
  void dispose() {
    timer?.cancel();
    controller.dispose();
    controller.whenDisposed.whenComplete(() {
      physics.clearBindings();
      world.close();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Physics Lab'), toolbarHeight: 44),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(onPressed: spawn, child: const Text('Drop ball')),
              OutlinedButton(
                onPressed: () {
                  setState(() => physics.paused = !physics.paused);
                },
                child: Text(physics.paused ? 'Resume' : 'Pause'),
              ),
              OutlinedButton(onPressed: reset, child: const Text('Reset')),
              FilterChip(
                label: const Text('Debug'),
                selected: physics.debug,
                onSelected: (value) {
                  setState(() => physics.debug = value);
                  controller.invalidate();
                },
              ),
              OutlinedButton(
                onPressed: () {
                  final hit = world.rayCast(
                    origin: const Vec3(-2, 8, 0),
                    direction: const Vec3(0, -1, 0),
                    filter: const QueryFilter(excludeSensors: true),
                  );
                  setState(
                    () => query = hit == null
                        ? 'Ray missed.'
                        : 'Ray hit collider ${hit.collider} at ${hit.time.toStringAsFixed(2)} m.',
                  );
                },
                child: const Text('Ray cast'),
              ),
              OutlinedButton(
                onPressed: () {
                  final hits = world.overlap(
                    shape: const SphereShape(2),
                    pose: PhysicsPose(position: const Vec3(-2, 1, 0)),
                  );
                  setState(
                    () => query = 'Overlap found ${hits.length} colliders.',
                  );
                },
                child: const Text('Overlap'),
              ),
              Text(
                'Contacts $collisions  Sensors $sensors  Bodies ${world.states.length}',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Text('Kinematic X'),
              Expanded(
                child: Slider(
                  value: target,
                  min: -4,
                  max: 4,
                  onChanged: (value) {
                    setState(() => target = value);
                    mover.setTarget(PhysicsPose(position: Vec3(value, .4, 2)));
                    controller.invalidate();
                  },
                ),
              ),
              SizedBox(width: 42, child: Text(target.toStringAsFixed(1))),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(query),
        ),
        Expanded(child: SceneView(controller: controller)),
      ],
    ),
  );
}
