import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'settings.dart';
import 'shapes.dart';

const particleStateFloats = 24;
const particleStateBytes = particleStateFloats * 4;

enum ParticlePlayback { stopped, playing, paused, draining }

final class ParticleTick {
  final int tick, firstSerial, count;
  final double step;
  const ParticleTick(this.tick, this.firstSerial, this.count, this.step);
  double get time => tick * step;
}

/// Fixed step clock. Excess elapsed time remains queued, never silently dropped.
/// At most maxSteps ticks run per call to bound work after a suspended viewport.
final class ParticleClock {
  final ParticleSettings settings;
  ParticlePlayback _playback = ParticlePlayback.stopped;
  double _accumulator = 0;
  int _tick = 0, _serial = 0, _manual = 0;
  int get tick => _tick;
  int get attempted => _serial;
  double get pendingSeconds => _accumulator;
  ParticlePlayback get playback => _playback;
  ParticleClock(this.settings);
  void start() {
    if (_playback == ParticlePlayback.stopped) reset();
    _playback = ParticlePlayback.playing;
  }

  void pause() {
    if (_playback == ParticlePlayback.playing ||
        _playback == ParticlePlayback.draining) {
      _beforePause = _playback;
      _playback = ParticlePlayback.paused;
    }
  }

  ParticlePlayback _beforePause = ParticlePlayback.playing;
  void resume() {
    if (_playback == ParticlePlayback.paused) _playback = _beforePause;
  }

  void stop({bool clear = false}) {
    if (clear) {
      reset();
    } else {
      _playback = ParticlePlayback.draining;
    }
  }

  void reset() {
    _tick = 0;
    _serial = 0;
    _manual = 0;
    _accumulator = 0;
    _playback = ParticlePlayback.stopped;
  }

  void burst(int count) {
    RangeError.checkValueInInterval(count, 1, settings.capacity, 'count');
    if (_manual + count > settings.capacity) {
      throw StateError('Queued bursts exceed capacity.');
    }
    _manual += count;
  }

  List<ParticleTick> advance(double seconds, {int maxSteps = 32}) {
    finiteRange(seconds, 'seconds', 0, 3600);
    RangeError.checkValueInInterval(maxSteps, 1, 4096, 'maxSteps');
    if (_playback == ParticlePlayback.paused ||
        _playback == ParticlePlayback.stopped) {
      return const [];
    }
    if (_accumulator + seconds > 3600) {
      throw StateError('Simulation backlog exceeds one hour.');
    }
    _accumulator += seconds;
    final output = <ParticleTick>[];
    while (_accumulator + 1e-12 >= settings.fixedStep &&
        output.length < maxSteps) {
      final start = _tick * settings.fixedStep;
      final end = (_tick + 1) * settings.fixedStep;
      var count = _manual;
      _manual = 0;
      if (_playback == ParticlePlayback.playing) {
        final emissionEnd = settings.looping
            ? end
            : math.min(end, settings.duration);
        if (start < emissionEnd) {
          count +=
              (emissionEnd * settings.rate + 1e-9).floor() -
              (start * settings.rate + 1e-9).floor();
          for (final burst in settings.bursts) {
            final firstCycle = settings.looping
                ? (start / settings.duration).floor()
                : 0;
            final lastCycle = settings.looping
                ? (emissionEnd / settings.duration).floor()
                : 0;
            for (var cycle = firstCycle; cycle <= lastCycle; cycle++) {
              final time = cycle * settings.duration + burst.time;
              if (time >= start - 1e-12 && time < emissionEnd - 1e-12) {
                count += burst.count;
              }
            }
          }
        }
        if (!settings.looping && end >= settings.duration) {
          _playback = ParticlePlayback.draining;
        }
      }
      if (_serial + count > 0xffffff || _tick >= 0xffffff) {
        throw StateError(
          'Reset the emitter before its serial or exact GPU tick range is exhausted.',
        );
      }
      output.add(ParticleTick(++_tick, _serial, count, settings.fixedStep));
      _serial += count;
      _accumulator = math.max(0, _accumulator - settings.fixedStep);
    }
    return output;
  }
}

/// Inspection snapshot. Reading it allocates, simulation state remains packed.
final class ParticleSnapshot {
  final int slot, serial;
  final Vec3 position, velocity, birthScale;
  final double age;
  const ParticleSnapshot({
    required this.slot,
    required this.serial,
    required this.position,
    required this.velocity,
    required this.age,
    this.birthScale = Vec3.one,
  });
}

/// Deterministic reference and supported compute-free simulation path.
/// State layout matches the shader: position/age, velocity/birth, serial/alive,
/// followed by three birth-transform columns.
final class ParticleReference {
  final ParticleSettings settings;
  final Float32List state, history;
  int spawned = 0, replaced = 0, dropped = 0;
  ParticleReference(this.settings)
    : state = Float32List(settings.capacity * particleStateFloats),
      history = Float32List(
        settings.capacity * (settings.trails?.samples ?? 2) * 4,
      );
  int get liveCount {
    var count = 0;
    for (var i = 0; i < settings.capacity; i++) {
      if (state[i * particleStateFloats + 9] != 0) count++;
    }
    return count;
  }

  List<ParticleSnapshot> get particles => [
    for (var slot = 0; slot < settings.capacity; slot++)
      if (state[slot * particleStateFloats + 9] != 0)
        ParticleSnapshot(
          slot: slot,
          serial: state[slot * particleStateFloats + 8].toInt(),
          position: Vec3.array(state, slot * particleStateFloats),
          velocity: Vec3.array(state, slot * particleStateFloats + 4),
          age: state[slot * particleStateFloats + 3],
          birthScale: Vec3(
            Vec3.array(state, slot * particleStateFloats + 12).length,
            Vec3.array(state, slot * particleStateFloats + 16).length,
            Vec3.array(state, slot * particleStateFloats + 20).length,
          ),
        ),
  ];
  void reset() {
    state.fillRange(0, state.length, 0);
    history.fillRange(0, history.length, 0);
    spawned = replaced = dropped = 0;
  }

  /// [origin] offsets packed positions into world coordinates for forces and
  /// collision planes. Keep it fixed until reset; local simulation uses zero.
  void step(
    ParticleTick tick, {
    Mat4? emitterTransform,
    Vec3 origin = Vec3.zero,
  }) {
    final transform = emitterTransform ?? Mat4.identity();
    final dt = tick.step, samples = settings.trails?.samples ?? 2;
    var accepted = 0;
    for (var slot = 0; slot < settings.capacity; slot++) {
      final o = slot * particleStateFloats;
      if (state[o + 9] != 0) {
        state[o + 3] = (tick.tick - state[o + 7]) * dt;
        if (state[o + 3] >= settings.lifetime) {
          state[o + 9] = 0;
        } else {
          var ax = settings.gravity.x,
              ay = settings.gravity.y,
              az = settings.gravity.z;
          for (final force in settings.forces) {
            final a = force.acceleration(
              Vec3.array(state, o) + origin,
              Vec3.array(state, o + 4),
              tick.time,
              state[o + 8].toInt(),
            );
            if (!a.isFinite) {
              throw StateError(
                'Particle force returned a nonfinite acceleration.',
              );
            }
            ax += a.x;
            ay += a.y;
            az += a.z;
          }
          final damping = 1 / (1 + settings.drag * dt);
          state[o + 4] = (state[o + 4] + ax * dt) * damping;
          state[o + 5] = (state[o + 5] + ay * dt) * damping;
          state[o + 6] = (state[o + 6] + az * dt) * damping;
          state[o] += state[o + 4] * dt;
          state[o + 1] += state[o + 5] * dt;
          state[o + 2] += state[o + 6] * dt;
          for (final plane in settings.collisions) {
            final n = plane.normal;
            final distance =
                state[o] * n.x +
                state[o + 1] * n.y +
                state[o + 2] * n.z +
                (plane.offset + origin.dot(n));
            if (distance < 0) {
              state[o] -= n.x * distance;
              state[o + 1] -= n.y * distance;
              state[o + 2] -= n.z * distance;
              final speed =
                  state[o + 4] * n.x + state[o + 5] * n.y + state[o + 6] * n.z;
              if (speed < 0) {
                final impulse = speed * (1 + plane.restitution);
                state[o + 4] -= n.x * impulse;
                state[o + 5] -= n.y * impulse;
                state[o + 6] -= n.z * impulse;
              }
            }
          }
        }
      }
      if (tick.count > 0) {
        // Drop keeps the first event for a free slot. Replacement keeps the last;
        // superseded zero-age events have no integration interval.
        final last = tick.firstSerial + tick.count - 1;
        final serial = settings.overflow == ParticleOverflow.dropNew
            ? tick.firstSerial + ((slot - tick.firstSerial) % settings.capacity)
            : last - ((last - slot) % settings.capacity);
        if (serial >= tick.firstSerial && serial >= 0 && serial <= last) {
          if (state[o + 9] == 0 ||
              settings.overflow == ParticleOverflow.replaceOldest) {
            if (state[o + 9] != 0) replaced++;
            final p = settings.shape.sample(
              particleRandom(settings.seed, serial, 0),
              particleRandom(settings.seed, serial, 1),
              particleRandom(settings.seed, serial, 2),
              particleRandom(settings.seed, serial, 3),
            );
            var v = Vec3(
              settings.velocity.x +
                  (particleRandom(settings.seed, serial, 4) * 2 - 1) *
                      settings.velocitySpread.x,
              settings.velocity.y +
                  (particleRandom(settings.seed, serial, 5) * 2 - 1) *
                      settings.velocitySpread.y,
              settings.velocity.z +
                  (particleRandom(settings.seed, serial, 6) * 2 - 1) *
                      settings.velocitySpread.z,
            );
            var position = p;
            if (settings.space == ParticleSpace.world) {
              position = transformParticlePoint(transform, p);
              v = transformParticlePoint(transform, v, direction: true);
            }
            state.setRange(o, o + particleStateFloats, [
              position.x,
              position.y,
              position.z,
              0,
              v.x,
              v.y,
              v.z,
              tick.tick.toDouble(),
              serial.toDouble(),
              1,
              0,
              0,
              ...transform.storage.take(12),
            ]);
            spawned++;
            accepted++;
          }
        }
      }
      final h = (slot * samples + tick.tick % samples) * 4;
      history[h] = state[o];
      history[h + 1] = state[o + 1];
      history[h + 2] = state[o + 2];
      history[h + 3] = state[o + 9] == 0 ? 0 : state[o + 7] + 1;
    }
    if (settings.overflow == ParticleOverflow.dropNew) {
      dropped += tick.count - accepted;
    } else {
      final superseded = math.max(0, tick.count - settings.capacity);
      spawned += superseded;
      replaced += superseded;
    }
  }
}

Vec3 transformParticlePoint(Mat4 matrix, Vec3 point, {bool direction = false}) {
  final m = matrix.storage, w = direction ? 0 : 1;
  return Vec3(
    m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12] * w,
    m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13] * w,
    m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14] * w,
  );
}
