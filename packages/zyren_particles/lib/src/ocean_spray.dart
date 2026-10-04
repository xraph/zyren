import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'plugin.dart';
import 'settings.dart';
import 'shapes.dart';

/// A mapped water event in the particle scene's world coordinates. Copy the
/// shared simulation tick, generation, source and sequence without retiming it.
final class OceanSprayEvent {
  final String source;
  final int sequence, tick, generation;
  final Vec3 position, velocity, surfaceNormal;
  final double energy;
  OceanSprayEvent({
    required this.source,
    required this.sequence,
    required this.tick,
    required this.generation,
    required this.position,
    required this.velocity,
    required this.surfaceNormal,
    required this.energy,
  }) {
    if (source.trim().isEmpty ||
        source.length > 128 ||
        sequence < 0 ||
        sequence > 9007199254740991 ||
        tick < 1 ||
        tick > 0xffffff ||
        generation < 0 ||
        !position.isFinite ||
        position.length > 1e12 ||
        !velocity.isFinite ||
        velocity.length > 1000 ||
        !surfaceNormal.isFinite ||
        (surfaceNormal.length - 1).abs() > 1e-6 ||
        !energy.isFinite ||
        energy < 0 ||
        energy > 1e6) {
      throw ArgumentError('Invalid timestamped spray event.');
    }
  }
}

enum OceanSprayAdmission {
  accepted,
  disabled,
  duplicate,
  wrongTime,
  sourceBudget,
  eventBudget,
}

/// Bounded native spray with an external fixed clock. Up to eight emitter lanes
/// accept one birth position each per tick. Source/sequence sorting makes lane
/// assignment deterministic. Lifetime overflow drops new droplets within each
/// lane, using the particle backend's explicit drop policy.
final class OceanSprayParticles {
  final ParticleController controller;
  final String name;
  final int hz, budget, maxSources, particlesPerEvent;
  final List<Group> _objects;
  final List<String> _names;
  final Map<String, int> _seen = {};
  int _tick = 0, _generation, _originTick = 0;
  bool _closed = false, _faulted = false;
  Future<void>? _pending, _closing;
  int get tick => _tick;
  int get generation => _generation;
  int get sourceCount => _seen.length;
  Map<String, int> get sourceWatermarks => Map.unmodifiable(_seen);
  List<Group> get objects => List.unmodifiable(_objects);
  int get geometryBytes => effectiveCapacity * 120;
  int get logicalBytes =>
      estimateBytes(budget: budget, maxEventsPerTick: math.max(1, lanes));
  int get scopedBytes => logicalBytes - geometryBytes;
  int get lanes => _names.length;
  int get effectiveCapacity => lanes == 0 ? 0 : lanes * (budget ~/ lanes);
  bool get isClosed => _closed || controller.isClosed;
  bool get isFaulted => _faulted;
  List<String> get emitterNames => List.unmodifiable(_names);
  OceanSprayParticles._(
    this.controller,
    this.name,
    this.hz,
    this.budget,
    this.maxSources,
    this.particlesPerEvent,
    this._generation,
    this._objects,
    this._names,
  );

  /// Descriptor payload for buffers, sprite textures and native quad geometry.
  /// Renderer bookkeeping, shader descriptors and driver residency are separate.
  static int estimateBytes({required int budget, int maxEventsPerTick = 8}) {
    if (budget < 0 ||
        budget > 65536 ||
        maxEventsPerTick < 1 ||
        maxEventsPerTick > 8) {
      throw ArgumentError('Invalid spray capacity or lane count.');
    }
    final lanes = math.min(maxEventsPerTick, budget);
    if (lanes == 0) return 0;
    final capacity = budget ~/ lanes;
    var sortCapacity = 1;
    while (sortCapacity < capacity) {
      sortCapacity *= 2;
    }
    // State 96, history 32 and native quad geometry 120 bytes per droplet.
    // Per lane: parameters 240, shape 16 and a 32x32 RGBA sprite 4096 bytes.
    return lanes * (capacity * 248 + sortCapacity * 8 + 4352);
  }

  static Future<OceanSprayParticles> create(
    ParticleController controller, {
    String name = 'ocean.spray',
    int hz = 60,
    int budget = 2048,
    int maxEventsPerTick = 8,
    int maxSources = 128,
    int particlesPerEvent = 32,
    int generation = 0,
    int seed = 1,
    bool autoAttach = true,
    int initialTick = 0,
    Map<String, int> sourceWatermarks = const {},
    int maxLogicalBytes = 64 * 1024 * 1024,
    int retainedBytes = 0,
    double lifetime = 2,
    Vec3 gravity = const Vec3(0, -9.81, 0),
    Vec3 anchor = Vec3.zero,
    Color3 litColor = const Color3(.8, .9, 1),
    Iterable<ParticlePlane> boundaries = const [],
  }) async {
    if (!anchor.isFinite ||
        anchor.length > 1e12 ||
        controller.isClosed ||
        name.trim().isEmpty ||
        name.length > 110 ||
        hz < 1 ||
        hz > 1000 ||
        budget < 0 ||
        budget > 65536 ||
        maxEventsPerTick < 1 ||
        maxEventsPerTick > 8 ||
        maxSources < 1 ||
        maxSources > 4096 ||
        particlesPerEvent < 1 ||
        particlesPerEvent > 4096 ||
        generation < 0 ||
        initialTick < 0 ||
        initialTick > 0xffffff ||
        sourceWatermarks.length > maxSources ||
        sourceWatermarks.entries.any(
          (e) =>
              e.key.trim().isEmpty ||
              e.key.length > 128 ||
              e.value < 0 ||
              e.value > 9007199254740991,
        ) ||
        maxLogicalBytes < 1 ||
        maxLogicalBytes > 1 << 30 ||
        retainedBytes < 0) {
      throw ArgumentError('Invalid bounded spray configuration.');
    }
    final watermarks = Map<String, int>.of(sourceWatermarks);
    if (estimateBytes(budget: budget, maxEventsPerTick: maxEventsPerTick) +
            retainedBytes >
        maxLogicalBytes) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Spray candidate and retained payload exceed the allowance.',
      );
    }
    final count = math.min(maxEventsPerTick, budget);
    final names = [for (var i = 0; i < count; i++) '$name.$i'];
    if (controller.names.length + count > 32 ||
        names.any(controller.names.contains)) {
      throw ArgumentError('Spray exceeds available particle emitter lanes.');
    }
    final objects = <Group>[], installed = <String>[];
    final collisionPlanes = List<ParticlePlane>.of(boundaries);
    try {
      for (var i = 0; i < count; i++) {
        final object = Group(name: names[i])..position = anchor;
        objects.add(object);
        await controller.add(
          ParticleEmitter(
            name: names[i],
            object: object,
            externallyDriven: true,
            autoAttach: autoAttach,
            settings: ParticleSettings(
              capacity: budget ~/ count,
              rate: 0,
              seed: seed + i,
              fixedStep: 1 / hz,
              lifetime: lifetime,
              gravity: gravity,
              drag: .2,
              space: ParticleSpace.world,
              shape: SphereParticleShape(radius: .03),
              velocitySpread: const Vec3(.25, .25, .25),
              collisions: collisionPlanes,
              appearance: ParticleAppearance.stretched,
              stretch: .04,
              color: ParticleGradient(
                red: ParticleCurve.constant(litColor.r),
                green: ParticleCurve.constant(litColor.g),
                blue: ParticleCurve.constant(litColor.b),
                alpha: ParticleCurve([
                  CurveKey(0, 0),
                  CurveKey(.05, .7),
                  CurveKey(.7, .5),
                  CurveKey(1, 0),
                ]),
              ),
              size: ParticleCurve([
                CurveKey(0, .025),
                CurveKey(.6, .018),
                CurveKey(1, .008),
              ]),
              texture: _sprayTexture,
            ),
          ),
        );
        installed.add(names[i]);
      }
      final result = OceanSprayParticles._(
        controller,
        name,
        hz,
        budget,
        maxSources,
        particlesPerEvent,
        generation,
        objects,
        names,
      );
      result._tick = initialTick;
      result._originTick = initialTick;
      result._seen.addAll(watermarks);
      return result;
    } catch (_) {
      if (!controller.isClosed) {
        for (final emitter in installed) {
          await controller.remove(emitter);
        }
      }
      rethrow;
    }
  }

  Future<T> _exclusive<T>(
    Future<T> Function() work, {
    bool recovery = false,
  }) async {
    if (isClosed || _pending != null || (_faulted && !recovery)) {
      throw StateError('Spray is closed, busy or requires reset.');
    }
    final done = Completer<void>();
    _pending = done.future;
    try {
      return await work();
    } finally {
      _pending = null;
      done.complete();
    }
  }

  /// One simulation timeline owns this adapter. Supply only this tick's events;
  /// its own budget is independent of interaction-field admission. Results keep
  /// input order. Invalid timestamps and duplicates never consume a lane.
  Future<List<OceanSprayAdmission>> advance(
    int tick, {
    Iterable<OceanSprayEvent> events = const [],
  }) {
    final input = events.take(257).toList();
    if (input.length > 256) {
      throw ArgumentError(
        'Spray admission supports at most 256 events per tick.',
      );
    }
    return _exclusive(() async {
      if (tick != _tick + 1 || tick > 0xffffff) {
        throw StateError('Advance exactly the next spray tick.');
      }
      final results = List.filled(input.length, OceanSprayAdmission.disabled);
      final order = List.generate(input.length, (i) => i)
        ..sort((a, b) {
          final source = input[a].source.compareTo(input[b].source);
          final sequence = input[a].sequence.compareTo(input[b].sequence);
          return source != 0
              ? source
              : sequence != 0
              ? sequence
              : a.compareTo(b);
        });
      final seen = Map<String, int>.of(_seen), admitted = <OceanSprayEvent>[];
      for (final i in order) {
        final e = input[i];
        if (e.tick != tick || e.generation != _generation) {
          results[i] = OceanSprayAdmission.wrongTime;
        } else if (lanes == 0) {
          results[i] = OceanSprayAdmission.disabled;
        } else if (seen.containsKey(e.source) &&
            e.sequence <= seen[e.source]!) {
          results[i] = OceanSprayAdmission.duplicate;
        } else if (!seen.containsKey(e.source) && seen.length >= maxSources) {
          results[i] = OceanSprayAdmission.sourceBudget;
        } else if (admitted.length >= lanes) {
          results[i] = OceanSprayAdmission.eventBudget;
        } else {
          results[i] = OceanSprayAdmission.accepted;
          admitted.add(e);
          seen[e.source] = e.sequence;
        }
      }
      try {
        for (var i = 0; i < lanes; i++) {
          var velocity = Vec3.zero;
          if (i < admitted.length) {
            final e = admitted[i];
            _objects[i].position = e.position;
            final amplitude = math.sqrt(e.energy);
            velocity =
                e.velocity + e.surfaceNormal * math.min(10, 4 * amplitude);
            final count = math.min(
              budget ~/ lanes,
              (particlesPerEvent * amplitude).ceil(),
            );
            if (count > 0) await controller.burst(_names[i], count);
          }
          await controller.step(
            _names[i],
            tick: tick - _originTick,
            emissionVelocity: velocity,
          );
        }
        _seen
          ..clear()
          ..addAll(seen);
        _tick = tick;
        return List.unmodifiable(results);
      } catch (_) {
        _faulted = true;
        rethrow;
      }
    });
  }

  Future<void> reset(int generation) => _exclusive(() async {
    if (generation <= _generation) {
      throw ArgumentError('Spray reset needs a newer generation.');
    }
    try {
      for (final name in _names) {
        await controller.reset(name);
        await controller.start(name);
      }
      _seen.clear();
      _tick = 0;
      _originTick = 0;
      _generation = generation;
      _faulted = false;
    } catch (_) {
      _faulted = true;
      rethrow;
    }
  }, recovery: true);

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending;
    if (!controller.isClosed) {
      for (final name in _names) {
        await controller.remove(name);
      }
    }
    for (final object in _objects) {
      object.parent?.remove(object);
    }
  }
}

final _sprayTexture = () {
  const size = 32;
  final rgba = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final u = (x + .5) * 2 / size - 1, v = (y + .5) * 2 / size - 1;
      final r = u * u + v * v, alpha = r < 1 ? math.pow(1 - r, 2) : 0;
      rgba.setRange((y * size + x) * 4, (y * size + x) * 4 + 4, [
        255,
        255,
        255,
        (255 * alpha).round(),
      ]);
    }
  }
  return ParticleTexture(width: size, height: size, rgba: rgba);
}();
