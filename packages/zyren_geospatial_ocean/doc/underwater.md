# Underwater rendering

Use the same water meshes for the visible surface and `OceanSurfaceCapture`.
The capture records the nearest displaced interface on the GPU. Its view has an
independent near plane, so entering a wave does not lose the water boundary when
the main camera clips it. The surface shader also preserves that visible interface
through near-plane changes. Perspective and orthographic cameras support standard
and reversed depth.

Create the capture once for a stable set of water materials and geometry:

```dart
final surface = await OceanSurfaceCapture.create(
  scope,
  captureBackend,
  draws: [OceanBoundaryDraw(water: water, mesh: waterMesh)],
  size: viewport,
);
final underwater = await OceanUnderwaterPass.create(
  scope,
  surface: surface,
  optics: optics,
  lighting: lighting,
  settings: OceanUnderwaterSettings(shaftSteps: 16, particleBudget: 256),
);
```

`captureBackend` implements core's `CaptureBackend`, available from
`package:zyren/rendering.dart`. The native view keeps capture attachments separate
from the main view's opaque inputs and history. Capture is one sample per pixel;
its waterline is not a per-MSAA-sample volume classification.

Before each corresponding scene submission:

```dart
await surface.update(camera);
await underwater.prepare(
  camera: camera,
  viewport: viewport,
  signedSurfaceDistance: cameraSurfaceDistance,
  surfaceUp: localUp,
);
underwater.attach(scene);
```

The signed distance is negative in water. Supply it from a successful surface
query, along with the unit local up direction. Do not substitute zero for a failed
or stale query. Captured facing determines optical clipping where a surface hit
exists. Rays without a hit use the supplied distance; orthographic ray origins use
its local tangent plane. Include every visible water patch in the capture.

A changed camera, geometry revision, transform, visibility or morph pose needs a
fresh capture. A changed wave snapshot, material or geometry object needs a new
capture owner. A capture must have the same aspect ratio as the submitted view.
The distance encoding contributes at most 8 mm of half-float quantization below
60 km. Geometry LOD, pixel coverage and source accuracy are separate limits.

`OceanSubmersion` supplies entry/exit hysteresis for audio and particles. It does
not replace per-pixel optical classification. Replacing an attached underwater
pass transfers its effect slot after the candidate has compiled and prepared.
Closing the previous pass cannot remove its replacement.

## Air and water

When you use `AtmospherePlugin`, request transport output and pass that output to
the atmosphere. This keeps air fog out of the water interval:

```dart
final underwater = await OceanUnderwaterPass.create(
  scope,
  surface: surface,
  optics: optics,
  lighting: lighting,
  transportSize: viewport,
);
await atmosphere.controller.setAerialInputs(AerialPerspectiveInputs(
  medium: underwater.aerialMedium,
  // Include your existing normal, lighting-mask and overlay inputs here.
));
```

The producer runs before the atmosphere and leaves scene color unchanged. The
atmosphere applies far air, water transport and near air in that order. The
transport map must match the viewport. Rebuild it on resize, install its aerial
inputs and prepare the new producer before submitting the next frame. Keep the
producer alive while the atmosphere consumes its map. Clear or replace those aerial
inputs before closing it.

Without `transportSize`, the underwater pass applies its own premultiplied color
transport. Do not run a separate full-ray air-fog pass over that result. Both paths
preserve a transparent background. Ordered transparent foreground media and cloud
overlays need their own composition rules; this is not a general path tracer.

## Lighting and bounds

`OceanLighting` accepts explicit linear radiance, retained atmosphere LUTs or a
native convolved environment. Underwater scattering and caustic receivers use the
same irradiance source as the surface. For a local scene, provide a proper rigid
`worldToEcef` transform; volume planes, camera and `surfaceUp` stay in scene axes.
Light directions remain ECEF. Metres are required throughout.

`OceanWaterVolume` intersects up to six half-spaces. Use `OceanWaterVolume.box`
for a bounded region, or no planes when surface and scene depth supply the limits.
The pass stops at the nearest scene geometry, water interface, volume boundary or
configured integration limit. It does not continue fogging through air beyond a
pool or tank.

Shaft steps control actual single-scattering samples. Zero removes that direct
contribution. Incoming light depth uses a local water-plane approximation. Supply
`OceanSunVisibility` for projected sunlight visibility; absent visibility is
reported through `hasShadowVisibility == false`. No renderer shadow map is implied.

## Caustics

`OceanCaustics.create` refracts filtered wave triangles onto a bounded tangent
receiver. Set the resolution through `OceanUnderwaterSettings.causticResolution`.
Zero returns null and allocates nothing. The footprint must fit inside the source
patch, and an explicit logical byte budget rejects oversized candidates.

The pass adds overlapping light projections, caps concentration and bounds mean
irradiance by incoming horizontal sunlight. It includes light-path attenuation and
Fresnel loss. This is a projected approximation. Occlusion requires the optional
visibility input, and the receiver is planar at the specified depth.

Use `createReceiverMaterial` for a Lambertian receiver whose direct sunlight comes
from this pass. It accepts an ECEF geometry origin, albedo and ambient radiance.
The receiver's caustic direct term is zero outside the projected footprint or
receiver thickness. Its retained texture remains valid until your receiving scope
closes. For custom rendering, the caustic texture contains linear RGB irradiance
multipliers in a top-left image; east runs right and north runs up.

## Suspended matter and retirement

The optional `package:zyren_particles/ocean.dart` adapter consumes
`settings.particleBudget` and `underwater.submersion.submerged`. It owns native
capacity and clears particles when leaving water. Supply a wet emission region,
current velocity and lit color. See the [particle adapter](../../zyren_particles/doc/ocean.md).

Close the underwater pass, surface capture, caustics and their receiving scopes
when their registrations retire. Main-view submissions can retain accepted draw
resources until the next cleared scene is submitted. Logical byte counters describe
owned payloads, not measured physical GPU residency or FPS.

See [native qualification](../../../qualification/2026-10-03/ocean-underwater.md)
for fixture coverage and remaining scene/device checks.
