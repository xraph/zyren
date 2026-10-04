/// Optional ocean presentation adapter. It depends only on the particle API and
/// core scene types. Pass your ocean's particle budget and submersion state in.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'zyren_particles.dart';

/// Suspended matter advected in world space. The caller chooses a wet emission
/// region and supplies its lit color. This adapter does not query bathymetry,
/// shade particles with an implicit light, or advance rigid-body simulation.
final class OceanSuspendedParticles {
  final ParticleController controller;
  final String name;
  final Group object;
  bool _installed = false, _submerged = false, _closed = false;
  Future<void> _queue = Future.value();
  OceanSuspendedParticles(this.controller, {this.name = 'ocean.suspended'})
    : object = Group(name: name) {
    if (name.isEmpty || name.length > 128 || controller.names.contains(name)) {
      throw ArgumentError(
        'Suspended particles require an unused emitter name.',
      );
    }
  }
  bool get isClosed => _closed || controller.isClosed;
  bool get enabled => _installed && _submerged && !isClosed;
  Vec3 get position => object.position;
  set position(Vec3 value) {
    if (isClosed) throw StateError('Suspended particles closed.');
    object.position = value;
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) {
      if (isClosed) throw StateError('Suspended particles closed.');
      return action();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// A zero budget removes the emitter and its resources. Nonzero changes use
  /// the controller's atomic replacement and restart the deterministic visual
  /// population. Update position independently so camera motion keeps old
  /// particles at their world positions. Boundaries are optional collision planes.
  Future<void> configure({
    required int budget,
    required double radiusMetres,
    required Color3 litColor,
    Vec3 currentVelocity = Vec3.zero,
    int seed = 1,
    double opacity = .12,
    double sizeMetres = .015,
    Iterable<ParticlePlane> boundaries = const [],
  }) {
    if (budget < 0 ||
        budget > 65536 ||
        !radiusMetres.isFinite ||
        radiusMetres <= 0 ||
        radiusMetres > 1000 ||
        !sizeMetres.isFinite ||
        sizeMetres <= 0 ||
        sizeMetres > 1 ||
        !opacity.isFinite ||
        opacity < 0 ||
        opacity > 1) {
      throw ArgumentError(
        'Invalid suspended particle budget, radius, size or opacity.',
      );
    }
    // Construct before queuing so mutable iterables cannot change accepted input.
    final settings = budget == 0
        ? null
        : ParticleSettings(
            capacity: budget,
            seed: seed,
            lifetime: 10,
            rate: budget / 10,
            duration: 10,
            fixedStep: 1 / 60,
            prewarm: .5,
            gravity: Vec3.zero,
            drag: .05,
            velocity: currentVelocity,
            velocitySpread: const Vec3(.002, .002, .002),
            shape: SphereParticleShape(radius: radiusMetres),
            space: ParticleSpace.world,
            color: ParticleGradient(
              red: ParticleCurve.constant(litColor.r),
              green: ParticleCurve.constant(litColor.g),
              blue: ParticleCurve.constant(litColor.b),
              alpha: ParticleCurve([
                CurveKey(0, 0),
                CurveKey(.1, opacity),
                CurveKey(.8, opacity),
                CurveKey(1, 0),
              ]),
            ),
            size: ParticleCurve.constant(sizeMetres),
            collisions: boundaries,
            texture: _dustTexture,
          );
    return _serial(() async {
      if (settings == null) {
        if (_installed) await controller.remove(name);
        _installed = false;
      } else if (_installed) {
        await controller.configure(name, settings);
      } else {
        await controller.add(
          ParticleEmitter(
            name: name,
            settings: settings,
            object: object,
            autoStart: _submerged,
          ),
        );
        _installed = true;
      }
    });
  }

  /// Feed the ocean's hysteretic state. Leaving water clears existing particles
  /// as well as stopping emission, so old billboards do not float in the air.
  Future<void> setSubmerged(bool submerged) => _serial(() async {
    if (_submerged == submerged) return;
    if (_installed) {
      if (submerged) {
        await controller.start(name);
      } else {
        await controller.stop(name, clear: true);
      }
    }
    _submerged = submerged;
  });

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _queue;
    if (_installed && !controller.isClosed) await controller.remove(name);
    _installed = false;
  }
}

final _dustTexture = () {
  const size = 16;
  final pixels = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final u = (x + .5) * 2 / size - 1, v = (y + .5) * 2 / size - 1;
      final radius = u * u + v * v, at = (y * size + x) * 4;
      final alpha = radius >= 1 ? 0 : math.exp(-4 * radius) * (1 - radius);
      pixels.setRange(at, at + 4, [255, 255, 255, (255 * alpha).round()]);
    }
  }
  return ParticleTexture(width: size, height: size, rgba: pixels);
}();
