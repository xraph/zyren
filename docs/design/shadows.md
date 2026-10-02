# Native shadows

You opt in per light and per mesh:

```dart
final sun = scene.add(DirectionalLight(
  intensity: 3,
  shadow: DirectionalShadow(distance: 100, cascades: 3),
));
final object = scene.add(Mesh(BoxGeometry(), StandardMaterial())
  ..castShadow = true
  ..receiveShadow = true);
final floor = scene.add(Mesh(PlaneGeometry(width: 20, height: 20),
  StandardMaterial(roughness: 1))..receiveShadow = true);
```

Set `light.shadow = null` to disable that light's shadows. You can replace an
immutable settings object with `copyWith`, or call `light.invalidateShadow()`
when you need to force a depth refresh. Ordinary scene edits invalidate it for
you. The PBR example has a shadow toggle in its header.

Receivers require `StandardMaterial`. Built-in opaque and masked triangle
materials can cast, including `UnlitMaterial`. Casting from blend materials,
lines, points or custom vertex shaders fails explicitly. Custom deformation
needs its own matching depth program before that profile can be supported.

## Light settings

Directional lights use one to four camera-fitted cascades, with three by
default. `distance` limits coverage from the camera to at most 1,000,000 world
units. `splitLambda` mixes uniform and logarithmic splits, and `blend` overlaps
the end of each interval with the next one. The defaults are .5 and .1.
Directional maps include off-camera casters whose bounds overlap a cascade,
and their projected centres snap to shadow texels to reduce movement shimmer.

Spotlights use a perspective map that follows the outer cone. Point lights use
six perspective faces. Both accept `near` and `far`, defaulting to .1 and 100;
a finite light range further limits the far plane. A shadowed spotlight needs
a nondegenerate perspective cone. These checks fail before GPU submission.

```dart
scene.add(SpotLight(shadow: SpotShadow(resolution: 512, far: 40)));
scene.add(PointLight(shadow: PointShadow(resolution: 256, far: 20)));
sun.shadow = sun.shadow!.copyWith(normalBias: .01, filterRadius: 1.5);
```

`resolution` applies to each cascade or point face. You can use powers of two
from 128 to 1024. Directional and spot maps default to 512, point maps to 256.

| Setting | Default | Meaning |
| --- | --- | --- |
| `bias` | .0005 | Positive normalized depth offset toward the light, up to .1 |
| `normalBias` | .02 | Receiver offset along its face-oriented geometric normal, in world units |
| `slopeBias` | .002 | Extra depth offset at grazing light angles, up to .1 |
| `filterRadius` | 1 | Nine comparison taps, spread by 0..4 shadow texels |
| `strength` | 1 | Direct-light shadow opacity, from 0 to 1 |

Start with the defaults, then tune bias for your scene's scale. Too little can
produce self-shadowing artifacts; too much detaches shadows from their casters.
Normal maps also affect the receiver bias direction. Shadows
attenuate only the relevant punctual or area light. Environment lighting, hemisphere
lighting and emission remain intact.

Rectangular lights accept `AreaShadow`, with the same positional clipping,
bias and strength settings. Its default resolution is 128. Four emitter regions
each use six cube faces, for 24 views per light. Lighting integrates each region
separately and applies visibility at that region's centre. Four area emitters fit
at default resolution; larger faces compete with all other lights for atlas space.

```dart
scene.add(RectAreaLight(width: 2, height: 1, shadow: AreaShadow(far: 40)));
```

## Native ownership and limits

Dart calculates shadow views in float64 at the camera origin. The renderer
receives float32 matrices in the same coordinate system as scene geometry.
This keeps geospatial scenes on the ordinary core path.

Each active view owns a 2048 by 2048 `Depth32Float` atlas, 16 MiB. One device can
own at most four atlases, or 64 MiB. A frame can contain at most 128 shadow views
and 65,536 caster draws. Maps are packed in descending size without overlap;
requests that exceed the atlas or device budget fail without dropping a light.
Reducing map resolution fits more lights into one atlas but does not change
that atlas's allocated size.

The renderer reuses an atlas while its captured depth inputs are unchanged.
The cache compares geometry versions, caster transforms, material sidedness,
alpha masks and their samplers, shadow matrices and settings. A dirty atlas
redraws all its requested views. Masked depth uses the same UV set, texture,
sampler, opacity and cutoff as the visible material. Comparison taps clamp to
the selected atlas region to prevent filtering into another light's map.

Moving your camera reuses point, spot and area maps when their casters and lights
stay fixed. The cache retains exact float64 world transforms, so even a small
world edit invalidates depth when the camera moves with it. Rendering still uses
camera-relative float32 coordinates. Area emitters also retain their exact world
half-width and half-height vectors: resizing, scaling or rotating the emitter
moves its four shadow sample origins and must refresh depth. Directional
cascades, clipped casters and
older packets without world metadata keep conservative invalidation.

A successful GPU submission publishes the cached depth state. Disabling all
shadow lights releases the atlas, as does closing its native view. Failed
admission preserves the existing view, and closing another view lets you retry
a budget rejection. Internal atlas ownership lasts through GPU completion and
follows device retirement on failure.

You can inspect this separately from application-owned resource scopes:

```dart
final stats = await backend.shadowStats();
print('${stats.atlasCount} atlases, ${stats.residentBytes} bytes');
print('${stats.renderedViews} depth views, ${stats.reusedFrames} reused frames');
```

This diagnostic belongs to `NativeGpuBackend`. Check `RenderFeature.shadows`
when using another backend; `SceneEngine` rejects unsupported adapters before
rendering. The legacy JSON scene API cannot represent these settings.

## Profile and verification

The current profile uses cascaded directional maps, perspective spot maps and
six point faces with bounded PCF. Point-face filtering clamps at face edges;
cross-face seamless filtering, contact-hardening shadows, transmission and
custom depth materials remain follow-on work. Ordinary shadow mapping also
retains its resolution and bias limits. This is not full Three.js parity.

Core tests cover cascade stability, off-camera casters, clipping, immutable
bounds and admission. Native pixel probes cover cascade blend intervals,
all six point faces, planet-scale origins, geometry edits, mirrored alpha masks,
opacity, shadow strength and emission. Resource tests check cache reuse,
explicit refresh, release and recovery from the device atlas limit. Packet
tests reject malformed fields and every truncated message.

Translation tests compare cached depth with a forced redraw at ordinary and
Earth-scale origins. Before this cache change, each camera move redrew 6 point
faces, 1 spot face or 24 area faces. These fixtures now redraw zero faces for
camera movement alone, with matching visible shadows and unchanged 16 MiB atlas
residency. This measures avoided depth work, not an end-to-end frame-rate gain.

Cascade fitting and stabilization follow the techniques described in
[Microsoft's cascaded shadow map guide](https://learn.microsoft.com/en-us/windows/win32/dxtecharts/cascaded-shadow-maps).
See [verification](../verification.md) for the tested devices and commands.
