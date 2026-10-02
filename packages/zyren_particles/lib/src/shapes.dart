import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// Same unsigned hash is used in Dart and WGSL. Channels are independent.
int particleHash(int value) {
  var x = value & 0xffffffff;
  x = ((x ^ (x >> 16)) * 0x7feb352d) & 0xffffffff;
  x = ((x ^ (x >> 15)) * 0x846ca68b) & 0xffffffff;
  return (x ^ (x >> 16)) & 0xffffffff;
}

double particleRandom(int seed, int serial, int channel) =>
    (particleHash(
          seed ^
              ((serial * 747796405) & 0xffffffff) ^
              ((channel * 2891336453) & 0xffffffff),
        ) >>
        8) /
    16777216;

/// Extend emission with a matching reference sampler and WGSL body.
/// The body receives random r (four channels) and returns a local `vec3<f32>`.
/// surface is a read-only `array<vec4<f32>>` containing [gpuData].
abstract interface class ParticleShape {
  Vec3 sample(double a, double b, double c, double d);
  String get wgslBody;
  Float32List get gpuData;
  Vec3 get min;
  Vec3 get max;
}

final class PointParticleShape implements ParticleShape {
  final Vec3 position;
  PointParticleShape({this.position = Vec3.zero}) {
    if (!position.isFinite) throw ArgumentError('Point must be finite.');
  }
  @override
  Vec3 sample(double a, double b, double c, double d) => position;
  @override
  String get wgslBody =>
      'return vec3<f32>(${position.x},${position.y},${position.z});';
  @override
  Float32List get gpuData => Float32List(4);
  @override
  Vec3 get min => position;
  @override
  Vec3 get max => position;
}

final class BoxParticleShape implements ParticleShape {
  final Vec3 halfExtent;
  BoxParticleShape({this.halfExtent = Vec3.one}) {
    if (!halfExtent.isFinite ||
        halfExtent.x <= 0 ||
        halfExtent.y <= 0 ||
        halfExtent.z <= 0) {
      throw ArgumentError('Box extents must be finite and positive.');
    }
  }
  @override
  Vec3 sample(double a, double b, double c, double d) => Vec3(
    (a * 2 - 1) * halfExtent.x,
    (b * 2 - 1) * halfExtent.y,
    (c * 2 - 1) * halfExtent.z,
  );
  @override
  String get wgslBody =>
      'return (r.xyz * 2. - vec3<f32>(1.)) * '
      'vec3<f32>(${halfExtent.x},${halfExtent.y},${halfExtent.z});';
  @override
  Float32List get gpuData => Float32List(4);
  @override
  Vec3 get min => -halfExtent;
  @override
  Vec3 get max => halfExtent;
}

final class SphereParticleShape implements ParticleShape {
  final double radius;
  final bool surfaceOnly;
  SphereParticleShape({this.radius = 1, this.surfaceOnly = false}) {
    if (!radius.isFinite || radius <= 0) {
      throw ArgumentError('Radius must be positive.');
    }
  }
  @override
  Vec3 sample(double a, double b, double c, double d) {
    final z = 2 * a - 1, angle = b * math.pi * 2;
    final radial = math.sqrt(math.max(0, 1 - z * z));
    final distance = radius * (surfaceOnly ? 1 : math.pow(c, 1 / 3).toDouble());
    return Vec3(radial * math.cos(angle), z, radial * math.sin(angle)) *
        distance;
  }

  @override
  String get wgslBody =>
      '''
let z = 2. * r.x - 1.; let angle = r.y * 6.283185307;
let radial = sqrt(max(0., 1. - z*z));
return vec3<f32>(radial*cos(angle), z, radial*sin(angle)) * $radius *
${surfaceOnly ? '1.' : 'pow(r.z, 0.3333333333)'};
''';
  @override
  Float32List get gpuData => Float32List(4);
  @override
  Vec3 get min => Vec3(-radius, -radius, -radius);
  @override
  Vec3 get max => Vec3(radius, radius, radius);
}

/// Uniform volume sampling of a cone along local +Y.
final class ConeParticleShape implements ParticleShape {
  final double radius, height;
  ConeParticleShape({this.radius = 1, this.height = 1}) {
    if (!radius.isFinite || radius <= 0 || !height.isFinite || height <= 0) {
      throw ArgumentError('Cone radius and height must be positive.');
    }
  }
  @override
  Vec3 sample(double a, double b, double c, double d) {
    final h = math.pow(a, 1 / 3).toDouble(), radial = math.sqrt(b) * radius * h;
    return Vec3(
      radial * math.cos(c * math.pi * 2),
      h * height,
      radial * math.sin(c * math.pi * 2),
    );
  }

  @override
  String get wgslBody =>
      '''
let h = pow(r.x, 0.3333333333); let radial = sqrt(r.y) * $radius * h;
return vec3<f32>(radial*cos(r.z*6.283185307), h*$height, radial*sin(r.z*6.283185307));
''';
  @override
  Float32List get gpuData => Float32List(4);
  @override
  Vec3 get min => Vec3(-radius, 0, -radius);
  @override
  Vec3 get max => Vec3(radius, height, radius);
}

/// Area weighted triangle sampling. Degenerate triangles are excluded.
final class SurfaceParticleShape implements ParticleShape {
  final Float32List _data;
  @override
  final Vec3 min, max;
  SurfaceParticleShape._(this._data, this.min, this.max);
  factory SurfaceParticleShape(GeometryData geometry) {
    if (geometry.topology != GeometryTopology.triangles ||
        geometry.indices.length > 196608) {
      throw ArgumentError('Surface emission supports up to 65536 triangles.');
    }
    final snapshot = BufferGeometry.fromData(geometry);
    final positions = snapshot.positions;
    final records = <double>[];
    var total = 0.0;
    var lo = const Vec3(double.infinity, double.infinity, double.infinity);
    var hi = const Vec3(
      double.negativeInfinity,
      double.negativeInfinity,
      double.negativeInfinity,
    );
    for (var i = 0; i < geometry.indices.length; i += 3) {
      final a = Vec3.array(positions, geometry.indices[i] * 3);
      final b = Vec3.array(positions, geometry.indices[i + 1] * 3);
      final c = Vec3.array(positions, geometry.indices[i + 2] * 3);
      final area = (b - a).cross(c - a).length * .5;
      if (area <= 1e-12) continue;
      total += area;
      records.addAll([
        a.x,
        a.y,
        a.z,
        total,
        b.x,
        b.y,
        b.z,
        0,
        c.x,
        c.y,
        c.z,
        0,
      ]);
      for (final p in [a, b, c]) {
        lo = Vec3(
          math.min(lo.x, p.x),
          math.min(lo.y, p.y),
          math.min(lo.z, p.z),
        );
        hi = Vec3(
          math.max(hi.x, p.x),
          math.max(hi.y, p.y),
          math.max(hi.z, p.z),
        );
      }
    }
    if (total == 0 || !total.isFinite) {
      throw ArgumentError('Surface needs finite nonzero area.');
    }
    for (var i = 3; i < records.length; i += 12) {
      records[i] /= total;
    }
    return SurfaceParticleShape._(Float32List.fromList(records), lo, hi);
  }
  @override
  Vec3 sample(double a, double b, double c, double d) {
    var lo = 0, hi = _data.length ~/ 12 - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (a <= _data[mid * 12 + 3]) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final index = lo * 12, root = math.sqrt(b);
    return Vec3.array(_data, index) * (1 - root) +
        Vec3.array(_data, index + 4) * (root * (1 - c)) +
        Vec3.array(_data, index + 8) * (root * c);
  }

  @override
  Float32List get gpuData => Float32List.fromList(_data);
  @override
  String get wgslBody =>
      '''
var lo = 0u; var hi = ${_data.length ~/ 12 - 1}u;
loop { if lo >= hi { break; } let mid = (lo+hi)/2u;
if r.x <= surface[mid*3u].w { hi = mid; } else { lo = mid+1u; } }
let root = sqrt(r.y); let index = lo*3u;
return surface[index].xyz*(1.-root) + surface[index+1u].xyz*(root*(1.-r.z)) +
 surface[index+2u].xyz*(root*r.z);
''';
}
