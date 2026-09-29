import 'dart:math' as math;
import 'package:zyren/zyren.dart';

// glTF Appendix B, evaluated as separate dielectric and conductor lobes.
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
  final dielectricF = .04 + .96 * weight;
  return [
    for (final color in [base.r, base.g, base.b])
      ((1 - metallic) *
                  ((1 - dielectricF) * color / math.pi +
                      dielectricF * specular) +
              metallic * (color + (1 - color) * weight) * specular) *
          nl,
  ];
}
