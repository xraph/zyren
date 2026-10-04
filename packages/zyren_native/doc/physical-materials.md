# Physical materials

Use `PhysicalMaterial` when you need clearcoat, sheen, anisotropy, thin films or
transmission. Its base surface keeps the standard material's metal/roughness maps,
linear data textures and sRGB color textures. glTF factors still multiply their
mapped channels. A zero factor disables the corresponding optional lobe.

The native shader specializes inactive lobes through pipeline constants. It also
prepares view-dependent GGX, coat and sheen terms once before the punctual-light
loop. A material with a metallic factor of one can still transmit when its
metallic map lowers the sampled value, so that combination keeps transmission.

You can use up to 512 distinct built-in pipelines and 128 physical-map binding
layouts in one frame. The renderer checks the combined scene, outline and
transmission passes before it changes the cache. It retires unused variants when
subsequent frames exceed the cache capacity, including retained bind groups that
refer to retired layouts. An oversized working set returns a descriptive error;
you can retry with a smaller set without losing the previous useful pipelines.
These bounds can reject unusually diverse scenes that an unbounded cache accepted.

New variants are created separately and published only after all GPU error scopes
succeed. If creation fails, you can retry the same material keys: the previous
pipelines and layouts remain available, and failed handles never enter the cache.
This transaction covers the complete scene, outline and transmission request.

Preparation can temporarily own up to 1024 pipeline handles and 256 physical-map
variant entries: the old cache plus one admitted candidate set. Each physical-map
entry owns a shader module, a binding layout and its pipeline layouts. Successful
publication returns the cache to 512/128; failed candidates are dropped. These
counts exclude fixed renderer pipelines and handles retained by already encoded
GPU work. Pipeline memory is driver dependent, so the count bounds are not a
physical residency or byte-budget measurement.

Native readback tests compare mapped PBR batches with separately ordered draws.
The coverage includes explicit tangent handedness, nonuniform scale and mixed
transform determinant signs. These fixtures verify material behavior and cache
handling. They do not measure foreground frame rate.

## Directional energy

The base GGX lobe uses the shape-preserving scaling approximation described by
[Turquin](https://blog.selfshadow.com/publications/turquin/ms_comp_final.pdf).
For Schlick normal reflectance F0 and white directional albedo E, its scale is
`1 + F0 * (1/E - 1)`. You get the same scale in punctual lighting, environment
lighting and the isotropic LTC area approximation. The anisotropic area path
integrates the punctual response. Clearcoat uses its own roughness and lookup.

This approximation restores the isotropic perfect-reflector furnace response
while retaining colored absorption. It is view dependent and not reciprocal.
The diffuse budget uses the compensated directional dielectric energy, including
thin-film color where active. Coat attenuation uses compensated coat energy;
Charlie sheen retains its existing fitted directional energy model.

Anisotropic GGX uses an isotropic energy lookup at the geometric mean of its two
GGX widths. You should expect incomplete energy restoration. Independent tests
at anisotropy 0.8, roughness 0.3/0.65/1, NdotV 1/0.5/0.087 and tangent azimuth
0/90 degrees measured white directional energy from 0.7551 to 1.0259. These are
measurements of that grid, not bounds for every material. The IBL bent-normal
prefilter and thin-film view-angle approximation also remain approximations.

Native HDR tests check selected film and coat combinations before tone mapping.
The tested normal-view thin-film thicknesses of 250 and 400 nm with half-strength
coat produced directional channel energies from 0.9694 to 0.9989. The isotropic
LTC tests differ from independent area integration by up to 1.6% at roughness
0.35/0.65/1. You cannot infer exact layered conservation or angular lobe agreement
from a furnace measurement alone.

## Lookup data and lifetime

All three built-in BRDF table generators share one canonical integral. Red stores
Schlick A and green stores B, so A+B is white directional energy. Both axes include
their endpoints: texel `(x,y)` represents `NdotV=x/(width-1)` and
`roughness=y/(height-1)`. The shader maps those coordinates to texel centers.
Caller-supplied BRDF maps need this convention too. A one-texel sampled dimension
uses its center; the built-in generators require larger validated dimensions.

At the exact grazing column, correlated Smith masking has the analytic limit
Ewhite=1. The integrator applies that constraint to A+B while retaining its sampled
A/B ratio. This removes the total-energy endpoint bias. It does not make the
colored split or adjacent near-grazing quadrature exact. GGX keeps alpha at least
0.002025, including an authored roughness of zero.

The renderer allocates a shared 128 by 128 RGBA16F fallback table only when a
prepared PBR frame needs it. A scene using a supplied environment BRDF skips that
allocation and generation pass. Once created, the table costs 131072 registry
bytes while a published or pending view retains PBR geometry, including culled
source meshes. It stays warm across environment switches until the last owner
releases it.
Generation uses 2048 samples per texel in one ordered GPU pass, with no additional
CPU fence. The frame profile reports `energyLut` and includes that draw in totals.
The generator adds one live pipeline while the table exists.

The table stays uninitialized until generation submits. Failed preparation can
retry it. Closing the last owner or publishing an empty scene removes retained
texture and bind-group aliases across views before registry retirement; a culled
source packet still owns its table. Allocation uses the scene budget, and the
immutable table has no replacement overlap or CPU upload staging allocation.

Regenerate the shipped Dart constant after editing the canonical native WGSL:

```sh
fvm dart run tool/generate_ggx_energy.dart
fvm dart run tool/generate_ggx_energy.dart --check
```

## Moving highlights

Standard and physical materials filter specular roughness from screen-space
normal variance. You get variance 0.15 and threshold 0.2 by default. The threshold
caps variance added to alpha squared, which is perceptual roughness to the fourth
power. It is not a roughness slider. Both settings accept finite values in [0,1].

```dart
final material = PhysicalMaterial(
  roughness: .2,
  clearcoat: .5,
  specularAntiAliasingVariance: .15,
  specularAntiAliasingThreshold: .2,
);
final unfiltered = material.copyWith(specularAntiAliasingVariance: 0);
```

Set either value to zero when you need the exact authored roughness. The filter
uses mapped base and coat normals before clipping or alpha discard; it adds
bounded derivative work per fragment and can broaden highlights. Constant normals
keep their roughness. It does not recover detail already lost during normal-map
minification, and it does not replace texture mipmaps or temporal antialiasing.

Indirect specular occlusion varies with roughness and the view-normal angle.
Diffuse ambient occlusion keeps its scalar map value. Punctual and area lighting
are unaffected by the ambient occlusion map. This is an empirical visibility
approximation, so an occlusion texture is still needed for local cavity detail.

Run Shader Lab's PBR example to compare the default with the `Specular AA` toggle.
The toggle changes the public material setting, including when textures are
switched off. Its controls wrap on narrow windows.
