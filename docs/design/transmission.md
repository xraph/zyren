# Transmission and volume

You can render glass without reducing its alpha coverage:

```dart
final glass = PhysicalMaterial(
  transmission: 1,
  roughness: .15,
  ior: 1.5,
  thickness: .8,
  attenuationColor: const Color3(.3, .8, .95),
  attenuationDistance: 2,
);
```

`transmission` replaces the diffuse contribution while retaining specular,
clearcoat and sheen reflection. Base color tints transmitted light. Thickness is
in mesh units and follows node and instance scale. Attenuation distance is in
world units; infinity, the default, disables absorption. Zero thickness produces
a thin surface. Transmission uses R and thickness uses G from their linear maps.
`copyWith` retains these values and has explicit map-removal flags.

The renderer captures opaque and masked scene color and depth, then shades the
full scene. Glass samples the capture at a projected refracted position. A
nine-tap filter approximates rough transmission. Foreground depth rejects invalid
samples; unavailable samples fall back to the straight view or environment.
Absorption follows Beer attenuation over the estimated travel distance. Volume
backfaces are discarded so a closed surface does not shade its exit twice.

This is an approximation using the visible scene. Overlapping glass layers do
not refract one another. Blended objects are excluded from the opaque capture.
Objects outside the capture cannot appear through refraction unless represented
by the environment. There are no caustics, internal bounces or dispersion. The
roughness filter is not an exact GGX transmission integral. Mesh thickness and
scale estimate the path through the medium; the renderer does not trace its exit.
Shadow maps keep their ordinary opaque or masked behavior.

Capture uses one sample even when the final scene uses 4x MSAA. HDR capture keeps
linear RGBA16F radiance; the default profile uses sRGB RGBA8. Both use Depth32F.
Temporal AA treats glass as reactive because its surface motion cannot describe
the scene seen through it. Clear glass therefore gets current-frame coverage,
while opaque surfaces retain temporal accumulation. Transparent canvases preserve
associated color and optical coverage through the existing alpha resolve.

One shared capture costs 12 bytes/pixel in HDR or 8 bytes/pixel in the default
profile. Its budget is 128 MiB, including overlap during replacement, with a
64 MiB color-attachment limit. Admission happens before scene uploads. Disabling
transmission or closing the owning view releases the capture. Two one-pixel
fallback bindings consume another eight payload bytes per renderer.
`NativeGpuBackend.transmissionStats()` reports these separately from scoped
resources, shadows and TAA. These counts exclude driver padding and caches.
Frame statistics include the extra opaque draws and triangles.

The glTF loader accepts `KHR_materials_transmission` and `KHR_materials_volume`
with factors, maps, UV selection and sampler state. Native checks cover Fresnel,
tint, absorption, node/instance scale, map channels, roughness, refraction,
foreground rejection, live background changes, alpha, cleanup and loaded models.

References: [Khronos transmission](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_transmission/README.md)
and [Khronos volume](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_materials_volume/README.md).
