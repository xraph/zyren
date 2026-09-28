# Environment lighting

You can light standard materials from an HDR panorama with one plugin per view:

```dart
final lighting = controller.use(EnvironmentLighting(intensity: 1));
final image = await controller.assets.load(
  AssetRequest(
    uri: Uri.parse('asset:///environments/studio.hdr'),
    loader: const HdrImageLoader(),
  ),
).result;
await lighting.setImage(image);
```

Register the plugin before mounting the controller's first view. You can also
pass an already loaded image to the constructor. Initial preparation completes
during attachment; later replacements keep the current lighting visible while
the GPU prepares the new map.

`setImage` completes when preparation finishes. The next frame selects the
replacement and retires the previous map. Requests run in order, and a failed
request leaves the active map intact. Pass null to clear the lighting. Disposing
the view cancels publication, drains accepted work and releases GPU ownership.

Intensity and rotation change without rebuilding the map:

```dart
lighting.intensity = .8;
lighting.rotation = Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2);
```

Import `dart:math` as `math` for that rotation example. Intensity scales the
environment's radiance before shading. Exposure still belongs to
`ColorPipeline` and affects the final composed image. The environment adds
lighting only; it does not replace the scene background.

## Input and filtering

Supply a top-down, 2:1 equirectangular `HdrImageData` in linear sRGB. The top
points toward +Y, the horizontal centre points toward +X, and u=.75 points toward
+Z. Rotation transforms these local directions into world directions. Alpha is
ignored. RGB must fit RGBA16F, so a channel above 65504 fails preparation.

The core prepares three textures through public compute and resource APIs:

- Diffuse radiance stores cosine-weighted irradiance divided by pi.
- Specular levels store GGX-filtered radiance at uniformly spaced perceptual
  roughness values. The last level stays 8 by 4 texels to retain direction.
- The BRDF lookup stores Fresnel scale and bias using correlated Smith
  visibility, matching the direct-light BRDF.

The default `EnvironmentQuality` uses a 256 by 128 specular map, a 64 by 32
diffuse map, a 128-square BRDF lookup and 256 samples per integration. Sizes must
be powers of two. Specular width is bounded to 16..1024, diffuse width to
16..256, BRDF width to 16..512 and sample count to 64..2048. The combined
integration budget is 256 million samples. A smaller profile prepares faster:

```dart
EnvironmentLighting(
  image: image,
  quality: const EnvironmentQuality(
    specularWidth: 128,
    diffuseWidth: 32,
    brdfSize: 64,
    samples: 128,
  ),
);
```

This uses the single-scattering split-sum approximation described in
[Real Shading in Unreal Engine 4](https://cdn2.unrealengine.com/Resources/files/2013SiggraphPresentationsNotes-26915738.pdf).
It assumes the normal and view direction coincide during specular prefiltering.
Very small bright sources and grazing reflections need higher sampling and
remain approximate. Diffuse attenuation uses dielectric Fresnel before the
metallic blend; the split-sum specular term interpolates the two reflectances.
This keeps radiance linear in metallic weight for a fixed surface and environment.
Multiple scattering compensation, local reflection probes,
parallax correction and a sky background renderer are outside this checkpoint.
This is not a claim of Three.js or Takram parity.

## Procedural sources and ownership

For a custom atmosphere or lighting plugin, claim `context.environment` during
attach. Only one provider can own a view's environment. Prepare a map from an
initialized, sampled 2:1 RGBA16F texture:

```dart
final map = await EnvironmentMap.prefilter(
  skyTexture,
  resources: context.resources,
);
// In beforeRender, after preparation succeeds:
context.environment.environment = Environment(map: map, intensity: 1);
```

Your source mips must contain finite, nonnegative radiance. A complete source
mip chain improves filtering of small lights. Preparation retains the source
until it finishes, so no CPU readback is required. Publish replacements in
`beforeRender` and close the previous map there, after the prior frame settles.
The supplied `EnvironmentLighting` plugin handles this lifecycle for images.

You can share a CPU image across devices. To share a prepared GPU map, call
`map.retain(otherResources)` on the same device. Closing either owner preserves
the other. New submissions reject a closed map or a map from another device;
accepted submissions hold its textures until completion. Geospatial remains
an optional consumer of these core extension points.

## Verification

The tests check constant HDR radiance, analytic directional convolution across
the panorama seam and poles, and BRDF values against independent angular
quadrature. Pixel probes cover rotation, roughness, occlusion, emission and a
missing environment. Lifecycle tests cover replacement failure, frame boundaries,
multiple views, disposal during preparation and cleanup failures.
The [material reference checks](material-reference-checks.md) also test metallic
interpolation at three viewing angles and three roughness values in linear HDR.

The sphere-grid example in `examples/shader_lab/lib/pbr.dart` includes an
analytic HDR studio panorama. Select Environment in its header to edit intensity
and rotation. Native Metal/Vulkan qualification uses the same numerical probes.
Other platform qualification and the broader PBR plan remain separate work.
