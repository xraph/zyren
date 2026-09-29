# Material reference checks

You can run the material probes against a native GPU from `packages/zyren_native`:

```sh
RUN_NATIVE_GPU=1 dart test test/pbr_reference_test.dart test/gltf_model_test.dart --concurrency=1
```

The Flutter target `examples/shader_lab/integration_test/pbr_pixels_test.dart`
runs the same numerical checks through Metal on macOS and Vulkan on Android.
The sphere grid in `examples/shader_lab/lib/pbr.dart` lets you inspect roughness,
metallic weight, maps, shadows and environment rotation interactively. Use the
numerical probes to assess radiance; the grid's tone-mapped image clips and
compresses values that the reference comparison needs to retain.

## Direct lighting

The CPU oracle evaluates separate dielectric and metal lobes from
[glTF Appendix B](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#appendix-b-brdf-implementation).
It uses double precision, a tangent-angle GGX distribution and Smith Lambda
masking. The shader uses float32, a cross-product distribution denominator and
the equivalent correlated visibility expression. Keeping these algebraic forms
different helps expose arithmetic defects shared code would reproduce.

The probe reads the centre of an odd-sized RGBA16F scene target before exposure,
tone mapping or sRGB conversion. A plane with normal +Z receives one white
directional light with unit intensity. Its base color is linear `(0.8, 0.3, 0.05)`.

| Parameter | Samples |
| --- | --- |
| View/light polar angles | `(0, 0)`, `(0, 37)`, `(35, 52)`, `(65, 70)`, `(40, 40)` degrees |
| Light azimuth for those pairs | `0`, `0`, `1.2`, `2.0`, `pi` radians |
| Perceptual roughness | `0`, `.045`, `.1`, `.3`, `.65`, `1` |
| Metallic weight | `0`, `.25`, `.5`, `.75`, `1` |

All 150 patches compare RGB with the CPU result. Per-channel tolerance is the
larger of `2e-5` and `0.3%` of reference radiance. Half-float storage alone can
round normal values by about `0.05%`; this allowance also covers float32 camera,
interpolation and shader arithmetic. Every sample must remain nonnegative and
finite, and alpha must equal one. Zero roughness uses the documented alpha floor
of `0.002025` in both implementations.

These probes exposed two defects: subtractive cancellation at glossy peaks and
diffuse attenuation that incorrectly used the mixed metal/dielectric Fresnel.
The stable GGX denominator is `|N x H|^2 + alpha^2 * (N.H)^2`. Diffuse light uses
dielectric Fresnel, then the metallic weight blends the complete responses.
The Rust and glTF pixel fixtures also pin a half-metallic material to its
independently calculated SDR value.

## Environment lighting

Another 45 patches use a constant HDR environment, view angles `0`, `55` and
`80` degrees, roughness `.1`, `.6` and `1`, and the same five metallic weights.
Intermediate radiance must equal the weighted blend of the measured dielectric
and metal endpoints, within the same tolerance. This checks material interpolation;
it does not establish exact integration of arbitrary environment lighting.

`support/environment_checks.dart` separately compares convolution with analytic
directional sources and the BRDF lookup with independent angular quadrature.
The current IBL profile remains a single-scattering split-sum approximation.
See [environment lighting](environment-lighting.md) for its sampling limits.

## Related fixtures

All paths below are relative to `packages/zyren_native/test`.

| Behaviour | Fixture |
| --- | --- |
| Light units, falloff, emission, masks and mirrored surfaces | `support/pbr_checks.dart` |
| Map transfer functions, channels, UV1, tangent handedness and occlusion | `support/standard_maps_checks.dart` |
| glTF defaults, maps, unlit materials, punctual lights and generated tangents | `support/gltf_pbr_checks.dart` |
| Cascades, point faces, masked shadows, bias, invalidation and large coordinates | `support/shadow_checks.dart` |
| Alpha sorting, overlap, depth writes and compositor alpha | `material_alpha_test.dart`, `scene_alpha_test.dart` |
| Exposure, HDR graph preservation and terminal conversion | `support/hdr_checks.dart` |

Sorted transparency retains the limits in [scene alpha](scene-alpha.md).
These fixtures qualify the implemented static material profile. Full glTF
conformance, advanced physical materials, area lights and the remaining platform
qualification require separate work.
