import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'shapes.dart';

void finiteRange(double value, String name, double min, double max) {
  if (!value.isFinite || value < min || value > max) {
    throw ArgumentError.value(value, name, 'Expected $min through $max.');
  }
}

enum ParticleSpace { local, world }

enum ParticleOverflow { dropNew, replaceOldest }

enum ParticlePath { gpu, reference }

enum ParticleAppearance { billboard, oriented, stretched, mesh }

enum ParticleBlend { alpha, additive, opaque }

final class CurveKey {
  final double time, value;
  CurveKey(this.time, this.value) {
    finiteRange(time, 'time', 0, 1);
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
  }
}

/// Piecewise linear keys, including both lifetime endpoints.
final class ParticleCurve {
  final List<CurveKey> keys;
  ParticleCurve(Iterable<CurveKey> keys) : keys = List.unmodifiable(keys) {
    if (this.keys.length < 2 ||
        this.keys.length > 64 ||
        this.keys.first.time != 0 ||
        this.keys.last.time != 1) {
      throw ArgumentError('Curves need 2 to 64 keys spanning 0 to 1.');
    }
    for (var i = 1; i < this.keys.length; i++) {
      if (this.keys[i].time <= this.keys[i - 1].time) {
        throw ArgumentError('Curve times must increase.');
      }
    }
  }
  factory ParticleCurve.constant(double value) =>
      ParticleCurve([CurveKey(0, value), CurveKey(1, value)]);
  double sample(double time) {
    finiteRange(time, 'time', 0, 1);
    for (var i = 1; i < keys.length; i++) {
      final b = keys[i], a = keys[i - 1];
      if (time <= b.time) {
        final t = (time - a.time) / (b.time - a.time);
        return a.value + (b.value - a.value) * t;
      }
    }
    return keys.last.value;
  }
}

final class ParticleGradient {
  final ParticleCurve red, green, blue, alpha;
  ParticleGradient({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
  }) {
    for (final curve in [red, green, blue, alpha]) {
      for (final key in curve.keys) {
        finiteRange(key.value, 'channel', 0, 1);
      }
    }
  }
  factory ParticleGradient.solid(Color3 color, {double opacity = 1}) =>
      ParticleGradient(
        red: ParticleCurve.constant(color.r),
        green: ParticleCurve.constant(color.g),
        blue: ParticleCurve.constant(color.b),
        alpha: ParticleCurve.constant(opacity),
      );
}

final class ParticleBurst {
  final double time;
  final int count;
  ParticleBurst({required this.time, required this.count}) {
    finiteRange(time, 'time', 0, 3600);
    RangeError.checkValueInInterval(count, 1, 65536, 'count');
  }
}

/// Acceleration in simulation coordinates. Custom forces provide both paths.
/// The WGSL body receives p, v, time and seed and returns `vec3<f32>`.
abstract interface class ParticleForce {
  Vec3 acceleration(Vec3 position, Vec3 velocity, double time, int seed);
  String get wgslBody;
}

final class ConstantParticleForce implements ParticleForce {
  final Vec3 value;
  ConstantParticleForce(this.value) {
    if (!value.isFinite) throw ArgumentError('Force must be finite.');
  }
  @override
  Vec3 acceleration(Vec3 position, Vec3 velocity, double time, int seed) =>
      value;
  @override
  String get wgslBody =>
      'return vec3<f32>(${value.x}, ${value.y}, ${value.z});';
}

/// Smooth spatial flow. Identical equations run on the GPU and reference path.
final class FlowParticleForce implements ParticleForce {
  final double amplitude, frequency, speed;
  FlowParticleForce({this.amplitude = 1, this.frequency = 1, this.speed = 1}) {
    finiteRange(amplitude, 'amplitude', 0, 10000);
    finiteRange(frequency, 'frequency', 0, 10000);
    finiteRange(speed, 'speed', -10000, 10000);
  }
  @override
  Vec3 acceleration(Vec3 p, Vec3 v, double time, int seed) =>
      Vec3(
        math.sin(p.y * frequency + time * speed),
        math.sin(p.z * frequency + time * speed + 2.0943951),
        math.sin(p.x * frequency + time * speed + 4.1887902),
      ) *
      amplitude;
  @override
  String get wgslBody =>
      'return sin(p.yzx * $frequency + '
      'vec3<f32>(time * $speed) + vec3<f32>(0.,2.0943951,4.1887902)) * $amplitude;';
}

final class ParticlePlane {
  final Vec3 normal;
  final double offset, restitution;
  ParticlePlane({required Vec3 normal, this.offset = 0, this.restitution = .5})
    : normal = normal.normalized() {
    if (!offset.isFinite) throw ArgumentError('Offset must be finite.');
    finiteRange(restitution, 'restitution', 0, 1);
  }
}

final class ParticleBox {
  final Vec3 min, max;
  final double restitution;
  ParticleBox({required this.min, required this.max, this.restitution = .5}) {
    if (!min.isFinite ||
        !max.isFinite ||
        min.x >= max.x ||
        min.y >= max.y ||
        min.z >= max.z) {
      throw ArgumentError('Collision bounds require finite increasing axes.');
    }
    finiteRange(restitution, 'restitution', 0, 1);
  }
  List<ParticlePlane> get planes => [
    ParticlePlane(
      normal: const Vec3(1, 0, 0),
      offset: -min.x,
      restitution: restitution,
    ),
    ParticlePlane(
      normal: const Vec3(-1, 0, 0),
      offset: max.x,
      restitution: restitution,
    ),
    ParticlePlane(
      normal: const Vec3(0, 1, 0),
      offset: -min.y,
      restitution: restitution,
    ),
    ParticlePlane(
      normal: const Vec3(0, -1, 0),
      offset: max.y,
      restitution: restitution,
    ),
    ParticlePlane(
      normal: const Vec3(0, 0, 1),
      offset: -min.z,
      restitution: restitution,
    ),
    ParticlePlane(
      normal: const Vec3(0, 0, -1),
      offset: max.z,
      restitution: restitution,
    ),
  ];
}

/// CPU texture pixels are copied so device restoration can rebuild the image.
final class ParticleTexture {
  final int width, height, columns, rows;
  final double framesPerSecond;
  final Uint8List _rgba;
  ParticleTexture({
    required this.width,
    required this.height,
    required Uint8List rgba,
    this.columns = 1,
    this.rows = 1,
    this.framesPerSecond = 0,
  }) : _rgba = Uint8List.fromList(rgba) {
    for (final value in [width, height]) {
      RangeError.checkValueInInterval(value, 1, 4096);
    }
    if (_rgba.length != width * height * 4 ||
        columns < 1 ||
        rows < 1 ||
        width % columns != 0 ||
        height % rows != 0) {
      throw ArgumentError('Texture pixels and atlas dimensions must agree.');
    }
    finiteRange(framesPerSecond, 'framesPerSecond', 0, 1000);
  }
  Uint8List get rgba => Uint8List.fromList(_rgba);
}

final class TrailSettings {
  final int samples;
  final double width;
  TrailSettings({this.samples = 16, this.width = .04}) {
    RangeError.checkValueInInterval(samples, 2, 64, 'samples');
    finiteRange(width, 'width', .000001, 10000);
  }
}

/// Immutable emitter configuration. Dynamics use a fixed tick, in seconds.
final class ParticleSettings {
  final int capacity, seed;
  final double lifetime, rate, duration, fixedStep, prewarm, drag, stretch;
  final Vec3 velocity, velocitySpread, gravity;
  final ParticleShape shape;
  final ParticleSpace space;
  final ParticleOverflow overflow;
  final ParticlePath path;
  final ParticleAppearance appearance;
  final ParticleBlend blend;
  final bool looping, depthTest, depthWrite, softIntersections;
  final List<ParticleBurst> bursts;
  final List<ParticleForce> forces;
  final List<ParticlePlane> collisions;
  final ParticleCurve size, rotation;
  final ParticleGradient color;
  final ParticleTexture? texture;
  final TrailSettings? trails;
  final GeometryData? mesh;
  ParticleSettings({
    this.capacity = 4096,
    this.seed = 1,
    this.lifetime = 2,
    this.rate = 100,
    this.duration = 5,
    this.fixedStep = 1 / 120,
    this.prewarm = 0,
    this.drag = 0,
    this.stretch = .1,
    this.velocity = Vec3.zero,
    this.velocitySpread = Vec3.zero,
    this.gravity = const Vec3(0, -9.81, 0),
    ParticleShape? shape,
    this.space = ParticleSpace.local,
    this.overflow = ParticleOverflow.dropNew,
    this.path = ParticlePath.gpu,
    this.appearance = ParticleAppearance.billboard,
    this.blend = ParticleBlend.alpha,
    this.looping = true,
    this.depthTest = true,
    this.depthWrite = false,
    this.softIntersections = false,
    Iterable<ParticleBurst> bursts = const [],
    Iterable<ParticleForce> forces = const [],
    Iterable<ParticlePlane> collisions = const [],
    ParticleCurve? size,
    ParticleCurve? rotation,
    ParticleGradient? color,
    this.texture,
    this.trails,
    this.mesh,
  }) : shape = shape ?? PointParticleShape(),
       bursts = List.unmodifiable(bursts),
       forces = List.unmodifiable(forces),
       collisions = List.unmodifiable(collisions),
       size = size ?? ParticleCurve.constant(.1),
       rotation = rotation ?? ParticleCurve.constant(0),
       color = color ?? ParticleGradient.solid(const Color3(1, 1, 1)) {
    RangeError.checkValueInInterval(capacity, 1, 65536, 'capacity');
    RangeError.checkValueInInterval(seed, 0, 0xffffffff, 'seed');
    finiteRange(lifetime, 'lifetime', .001, 3600);
    finiteRange(rate, 'rate', 0, 1000000);
    finiteRange(duration, 'duration', .001, 3600);
    finiteRange(fixedStep, 'fixedStep', 1 / 1000, .1);
    finiteRange(prewarm, 'prewarm', 0, 30);
    finiteRange(drag, 'drag', 0, 10000);
    finiteRange(stretch, 'stretch', 0, 10000);
    if (!velocity.isFinite ||
        !velocitySpread.isFinite ||
        !gravity.isFinite ||
        velocitySpread.x < 0 ||
        velocitySpread.y < 0 ||
        velocitySpread.z < 0) {
      throw ArgumentError(
        'Velocity, spread and gravity must be finite. Spread must be positive.',
      );
    }
    if (this.forces.length > 16 ||
        this.collisions.length > 12 ||
        this.bursts.length > 256 ||
        this.bursts.any((b) => b.time >= duration)) {
      throw ArgumentError('Emitter exceeds force, collision or burst limits.');
    }
    for (final key in this.size.keys) {
      finiteRange(key.value, 'size', 0, 10000);
    }
    if (appearance == ParticleAppearance.mesh && mesh == null ||
        mesh != null && mesh!.topology != GeometryTopology.triangles) {
      throw ArgumentError('Mesh particles require triangle geometry.');
    }
    final vertices = appearance == ParticleAppearance.mesh
        ? mesh!.layout.vertexCount
        : 4;
    final indices = appearance == ParticleAppearance.mesh
        ? mesh!.indices.length
        : 6;
    if (vertices * capacity > 1000000 ||
        indices * capacity > 3000000 ||
        capacity * (trails?.samples ?? 1) * 6 > 3000000) {
      throw ArgumentError(
        'Expanded particle or ribbon geometry exceeds native limits.',
      );
    }
  }
}
