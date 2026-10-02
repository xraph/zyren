import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import 'parameters.dart';
import 'luts.dart';
import 'table_decoder.dart';

/// Irradiance at one observer, before the receiving surface's cosine factor.
final class AtmosphereLightSample {
  final Vec3 sunIrradiance, skyIrradiance, upECEF;
  const AtmosphereLightSample._(
    this.sunIrradiance,
    this.skyIrradiance,
    this.upECEF,
  );
  Vec3 skyIrradianceAt(Vec3 normalECEF) =>
      skyIrradiance *
      ((1 + normalECEF.normalized().dot(upECEF)) * .5).clamp(0, 1);
}

/// Immutable CPU copy of the two small lighting tables. Sampling follows the
/// source SunDirectionalLight and SkyLightProbe helpers, including their UV
/// interpolation convention. You can reuse it without GPU readback each frame.
final class AtmosphereLightingSampler {
  final AtmosphereParameters parameters;
  final Float32List _transmittance, _irradiance;
  AtmosphereLightingSampler({
    required this.parameters,
    required Float32List transmittance,
    required Float32List irradiance,
  }) : _transmittance = _copy(transmittance, 256 * 64 * 4),
       _irradiance = _copy(irradiance, 64 * 16 * 4);

  static Float32List _copy(Float32List data, int length) {
    if (data.length != length ||
        data.any((v) => !v.isFinite || v < 0 || v > 65504)) {
      throw ArgumentError(
        'Lighting tables require finite nonnegative RGBA samples in the source layout.',
      );
    }
    return Float32List.fromList(data).asUnmodifiableView();
  }

  /// Reads RGBA16 or RGBA32 tables once, releasing temporary GPU retention.
  static Future<AtmosphereLightingSampler> read({
    required AtmosphereLuts luts,
    required GpuScope owner,
    void Function()? onReadback,
  }) async {
    final scope = owner.createChild(label: 'atmosphere lighting readback');
    try {
      Future<Float32List> values(GpuResource<Texture> texture) async {
        final retained = await scope.resources.retain(texture);
        final d = texture.descriptor as TextureDescriptor;
        final bytes = await scope.resources.readTexture(retained);
        onReadback?.call();
        if (d.format == TextureFormat.rgba16Float) {
          final table = AtmosphereTableDecoder().decode(
            bytes,
            format: AtmosphereLutFormat.binary,
            width: d.width,
            height: d.height,
          );
          return Float32List.fromList([
            for (var y = 0; y < d.height; y++)
              for (var x = 0; x < d.width; x++)
                for (var c = 0; c < 4; c++) table.value(x, y, 0, c),
          ]);
        }
        if (d.format != TextureFormat.rgba32Float) {
          throw ArgumentError('Unsupported lighting table precision.');
        }
        final data = ByteData.sublistView(bytes);
        return Float32List.fromList([
          for (var at = 0; at < bytes.length; at += 4)
            data.getFloat32(at, Endian.little),
        ]);
      }

      return AtmosphereLightingSampler(
        parameters: luts.parameters,
        transmittance: await values(luts.transmittance),
        irradiance: await values(luts.irradiance),
      );
    } finally {
      await scope.close();
    }
  }

  AtmosphereLightSample sample({
    required Vec3 positionECEF,
    required Vec3 sunDirectionECEF,
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    bool correctAltitude = true,
  }) {
    if (!positionECEF.isFinite ||
        positionECEF.length < 1 ||
        positionECEF.length > 1e12) {
      throw ArgumentError(
        'Lighting requires a finite ECEF observer outside the centre.',
      );
    }
    final sun = sunDirectionECEF.normalized();
    var camera = positionECEF;
    if (correctAltitude) {
      final surface = ellipsoid.projectOnSurface(camera);
      camera =
          camera -
          surface +
          ellipsoid.surfaceNormal(surface) * parameters.bottomRadius;
    }
    final radius = camera.length,
        mus = (camera.dot(sun) / radius).clamp(-1.0, 1.0);
    final sky = _sample(
      _irradiance,
      64,
      16,
      _unit(mus * .5 + .5, 64),
      _unit(
        (radius - parameters.bottomRadius) /
            (parameters.topRadius - parameters.bottomRadius),
        16,
      ),
    );
    final trans = _sunTransmittance(camera, sun);
    return AtmosphereLightSample._(
      _multiply(
        _multiply(trans, parameters.solarIrradiance),
        parameters.sunRelativeLuminance,
      ),
      _multiply(sky, parameters.skyRelativeLuminance),
      ellipsoid.surfaceNormal(camera),
    );
  }

  Vec3 _sunTransmittance(Vec3 camera, Vec3 sun) {
    var r = camera.length, rmu = camera.dot(sun);
    final top = parameters.topRadius, bottom = parameters.bottomRadius;
    final disc = rmu * rmu - r * r + top * top;
    if (disc >= 0) {
      final distance = -rmu - math.sqrt(disc);
      if (distance > 0) {
        r = top;
        rmu += distance;
      }
    }
    if (r > top) return const Vec3(1, 1, 1);
    final mu = (rmu / r).clamp(-1.0, 1.0);
    if (mu < 0 && rmu * rmu - r * r + bottom * bottom >= 0) return Vec3.zero;
    final h = math.sqrt(top * top - bottom * bottom),
        rho = math.sqrt(math.max(0, r * r - bottom * bottom));
    final d = math.max(
      0,
      -rmu + math.sqrt(math.max(0, rmu * rmu - r * r + top * top)),
    );
    final dmin = top - r, dmax = rho + h;
    return _sample(
      _transmittance,
      256,
      64,
      _unit((d - dmin) / (dmax - dmin), 256),
      _unit(rho / h, 64),
    );
  }
}

double _unit(double x, int size) => .5 / size + x * (1 - 1 / size);
Vec3 _multiply(Vec3 a, Vec3 b) => Vec3(a.x * b.x, a.y * b.y, a.z * b.z);
Vec3 _sample(Float32List data, int width, int height, double u, double v) {
  // The source CPU helpers use width-1, unlike GPU texel-centre interpolation.
  final x = u.clamp(0.0, 1.0) * (width - 1),
      y = v.clamp(0.0, 1.0) * (height - 1);
  final ix = x.floor(), iy = y.floor(), fx = x - ix, fy = y - iy;
  Vec3 pixel(int px, int py) {
    final at = ((py % height) * width + px % width) * 4;
    return Vec3(data[at], data[at + 1], data[at + 2]);
  }

  return (pixel(ix, iy) * (1 - fx) + pixel(ix + 1, iy) * fx) * (1 - fy) +
      (pixel(ix, iy + 1) * (1 - fx) + pixel(ix + 1, iy + 1) * fx) * fy;
}
