import 'dart:math' as math;
import 'package:zyren/zyren.dart';

// glTF GGX evaluated with independently sampled directional energy.
// Smith uses Lambda and GGX uses tan(theta), unlike the shader's dot-product
// visibility/distribution expressions. Radiance is double precision and linear.
List<double> referenceRadiance({
  required Vec3 view,
  required Vec3 light,
  required Color3 base,
  required double metallic,
  required double roughness,
}) {
  final nv = view.z, nl = light.z;
  if (nv <= 0 || nl <= 0) return [0, 0, 0];
  final half = (view + light).normalized(), nh = half.z.clamp(0.0, 1.0);
  final alpha = math.max(roughness * roughness, .002025),
      alpha2 = alpha * alpha;
  double lambda(double cosine) =>
      (math.sqrt(1 + alpha2 * (1 - cosine * cosine) / (cosine * cosine)) - 1) /
      2;
  final masking = 1 / (1 + lambda(nv) + lambda(nl));
  final cosine2 = nh * nh;
  final distribution = cosine2 == 0
      ? alpha2 / math.pi
      : 1 /
            (math.pi *
                alpha2 *
                cosine2 *
                cosine2 *
                math.pow(1 + (1 - cosine2) / (alpha2 * cosine2), 2));
  final specular = distribution * masking / (4 * nv * nl);
  final weight = math.pow(1 - view.dot(half).clamp(0.0, 1.0), 5).toDouble();
  final integral = referenceDirectionalEnergy(nv, roughness);
  final whiteEnergy = integral.$1 + integral.$2;
  final dielectricEnergy =
      (.04 * integral.$1 + integral.$2) * (1 + .04 * (1 / whiteEnergy - 1));

  return [
    for (final color in [base.r, base.g, base.b])
      ((1 - metallic) * (1 - dielectricEnergy) * color / math.pi +
              ((.04 * (1 - metallic) + color * metallic) +
                      (1 - (.04 * (1 - metallic) + color * metallic)) *
                          weight) *
                  specular *
                  (1 +
                      (.04 * (1 - metallic) + color * metallic) *
                          (1 / whiteEnergy - 1))) *
          nl,
  ];
}

final _energyCache = <(double, double, double, double), (double, double)>{};

// Heitz visible-normal sampling with a Halton disk sequence, independent of the
// shader bake's NDF half-vector Hammersley sequence and correlated dot formula.
// The estimator uses Smith Lambda and the visible-normal PDF cancellation.
(double, double) referenceDirectionalEnergy(
  double nv,
  double roughness, {
  double anisotropy = 0,
  double azimuth = 0,
}) => _energyCache.putIfAbsent((nv, roughness, anisotropy, azimuth), () {
  const samples = 65536;
  final alpha = math.max(roughness * roughness, .002025);
  final at = alpha + (1 - alpha) * anisotropy * anisotropy;
  final radial = math.sqrt(1 - nv * nv);
  final view = Vec3(radial * math.cos(azimuth), radial * math.sin(azimuth), nv);
  final stretched = Vec3(at * view.x, alpha * view.y, nv).normalized();
  final t1 = stretched.z < .999999
      ? Vec3(-stretched.y, stretched.x, 0).normalized()
      : const Vec3(1, 0, 0);
  final t2 = stretched.cross(t1);
  double radical(int value, int base) {
    var result = 0.0, factor = 1.0 / base;
    while (value > 0) {
      result += (value % base) * factor;
      value ~/= base;
      factor /= base;
    }
    return result;
  }

  double lambda(Vec3 direction) =>
      (math.sqrt(
            1 +
                (at * at * direction.x * direction.x +
                        alpha * alpha * direction.y * direction.y) /
                    (direction.z * direction.z),
          ) -
          1) /
      2;
  final lv = lambda(view), s = .5 * (1 + stretched.z);
  var a = 0.0, b = 0.0;
  for (var i = 1; i <= samples; i++) {
    final radius = math.sqrt(radical(i, 2));
    final angle = 2 * math.pi * radical(i, 3);
    final x = radius * math.cos(angle);
    final y = (1 - s) * math.sqrt(1 - x * x) + s * radius * math.sin(angle);
    final nh =
        t1 * x + t2 * y + stretched * math.sqrt(math.max(0, 1 - x * x - y * y));
    final h = Vec3(at * nh.x, alpha * nh.y, math.max(0, nh.z)).normalized();
    final vh = view.dot(h);
    final l = h * (2 * vh) - view;
    if (l.z <= 0) continue;
    final masking = (1 + lv) / (1 + lv + lambda(l));
    final fresnel = math.pow(1 - vh, 5).toDouble();
    a += masking * (1 - fresnel);
    b += masking * fresnel;
  }
  return (a / samples, b / samples);
});

List<int> referenceSrgbPixel({
  required Color3 base,
  required double metallic,
  required double roughness,
}) => [
  for (final value in referenceRadiance(
    view: const Vec3(0, 0, 1),
    light: const Vec3(0, 0, 1),
    base: base,
    metallic: metallic,
    roughness: roughness,
  ))
    (255 *
            (value <= .0031308
                ? 12.92 * value
                : 1.055 * math.pow(value, 1 / 2.4) - .055))
        .round()
        .clamp(0, 255),
  255,
];
