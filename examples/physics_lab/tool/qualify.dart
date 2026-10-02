import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

Future<void> main(List<String> arguments) async {
  final baseline = PhysicsWorld.nativeCounts;
  final world = PhysicsWorld(),
      scene = Scene()..background = const Color3(.04, .06, .09);
  final plugin = PhysicsPlugin(world: world, debug: true);
  final ground = world.createBody(
    kind: BodyKind.fixed,
    pose: PhysicsPose(position: const Vec3(0, -.5, 0)),
  );
  ground.addCollider(const BoxShape(Vec3(4, .5, 4)));
  scene
      .add(
        Mesh(
          BoxGeometry(width: 8, height: 1, depth: 8),
          DiffuseMaterial(color: const Color3(.2, .25, .3)),
        ),
      )
      .position = const Vec3(
    0,
    -.5,
    0,
  );
  final body = world.createBody(
    pose: PhysicsPose(position: const Vec3(0, 2, 0)),
  );
  body.addCollider(const SphereShape(.5));
  final mesh = scene.add(
    Mesh(
      SphereGeometry(radius: .5),
      DiffuseMaterial(color: const Color3(.95, .4, .1)),
    ),
  );
  plugin.bind(mesh, body);
  final anchor = world.createBody(
    kind: BodyKind.fixed,
    pose: PhysicsPose(position: const Vec3(2, 2.5, 0)),
  );
  final rotor = world.createBody(
    pose: PhysicsPose(position: const Vec3(2, 2.5, 0)),
  );
  rotor.addCollider(const BoxShape(Vec3(.8, .12, .12)));
  final arm = scene.add(
    Mesh(
      BoxGeometry(width: 1.6, height: .24, depth: .24),
      DiffuseMaterial(color: const Color3(.2, .65, .9)),
    ),
  );
  plugin.bind(arm, rotor);
  world.createJoint(
    body1: anchor,
    body2: rotor,
    kind: JointKind.hinge,
    axis: const Vec3(0, 0, 1),
    limits: [-.5, .5],
    motorVelocity: .4,
    maxForce: 100,
  );
  final camera = PerspectiveCamera(position: const Vec3(5, 4, 7))
    ..lookAt(const Vec3(0, .5, 0));
  SceneEngine? engine;
  final evidence = <String, Object?>{
    'platform': Platform.operatingSystem,
    'rapier': '0.36.0',
    'baseline': baseline,
  };
  try {
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: NativeRenderer.create,
      plugins: [plugin],
    );
    final backend = engine.capabilities.backend;
    if (backend == null || !{'Metal', 'Vulkan', 'Dx12'}.contains(backend)) {
      throw StateError('Unsupported native backend: $backend');
    }
    evidence['backend'] = backend;
    RenderedFrame? frame;
    for (var i = 0; i <= 120; i++) {
      frame = await engine.render(
        elapsed: Duration(microseconds: (i * 1000000 / 60).round()),
        width: 320,
        height: 240,
      );
    }
    evidence['ballY'] = body.state.pose.position.y;
    evidence['debugKinds'] = world
        .debugLines()
        .map((line) => line.kind)
        .toSet()
        .toList();
    if (!(evidence['debugKinds'] as List).toSet().containsAll([
      'collider',
      'contact',
      'joint',
    ])) {
      throw StateError('Native debug output lacks required geometry.');
    }
    plugin.paused = true;
    final settled = body.state.pose.position;
    await engine.dispose();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: NativeRenderer.create,
      plugins: [plugin],
    );
    frame = await engine.render(
      elapsed: Duration.zero,
      width: 640,
      height: 400,
    );
    if (body.state.pose.position != settled) {
      throw StateError('Renderer recreation changed the paused world.');
    }
    evidence['rendererRecreated'] = true;
    evidence['resizedTo'] = [frame.width, frame.height];
    evidence['pixelColors'] = {
      for (var i = 0; i < frame.pixels.length; i += 4)
        frame.pixels.sublist(i, i + 3).join(','),
    }.length;
    if ((evidence['pixelColors'] as int) < 20) {
      throw StateError('Native output lacks rendered geometry.');
    }
    if ((body.state.pose.position.y - .5).abs() > .05) {
      throw StateError('Native ball did not settle on ground.');
    }
    final destination = Directory(
      arguments.isEmpty ? 'qualification' : arguments.single,
    )..createSync(recursive: true);
    File(
      '${destination.path}/${backend.toLowerCase()}-physics.png',
    ).writeAsBytesSync(_png(frame));
    await engine.dispose();
    engine = null;
    if (scene.children.any((node) => node.name == 'Physics debug')) {
      throw StateError('Debug geometry leaked after detachment.');
    }
    plugin.clearBindings();
    world.close();
    evidence['afterClose'] = PhysicsWorld.nativeCounts;
    if (jsonEncode(evidence['afterClose']) != jsonEncode(baseline)) {
      throw StateError('Native physics world leaked.');
    }
    evidence['passed'] = true;
    File('${destination.path}/native-physics.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    );
    stdout.writeln(jsonEncode(evidence));
  } finally {
    await engine?.dispose();
    plugin.clearBindings();
    world.close();
  }
}

Uint8List _png(RenderedFrame frame) {
  final bytes = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    final length = ByteData(4)..setUint32(0, data.length);
    final checksum = ByteData(4)..setUint32(0, (crc ^ 0xffffffff) & 0xffffffff);
    bytes
      ..add(length.buffer.asUint8List())
      ..add(body)
      ..add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, frame.width)
    ..setUint32(4, frame.height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  final rows = BytesBuilder();
  for (var y = 0; y < frame.height; y++) {
    rows
      ..addByte(0)
      ..add(
        frame.pixels.sublist(y * frame.width * 4, (y + 1) * frame.width * 4),
      );
  }
  chunk('IDAT', ZLibEncoder().convert(rows.takeBytes()));
  chunk('IEND', []);
  return bytes.takeBytes();
}
