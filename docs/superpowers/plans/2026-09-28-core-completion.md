# Core feature completion

The core stays independent of geospatial. You use the same Dart scene and material
API on Metal, Vulkan and DX12. Each task below needs renderer evidence before its
API is described as implemented. User authorization covers implementation and
local commits; publication and merges are outside this work.

## 1. Physical materials

Extend standard metallic/roughness shading with dielectric IOR and specular
control, clearcoat, sheen and anisotropy. Keep standard-material output stable.
Preserve immutable copy semantics, texture ownership, UV selection, binary scene
deltas, instancing, skinning, shadows and HDR. Decode the corresponding glTF
material extensions. Test invalid factors, maps, native pixels and live edits.

Transmission and volume need an opaque scene capture and depth. Implement that
render stage before exposing transmission and thickness. Test refraction, rough
transmission, attenuation distance, opaque background changes and resource cleanup.

## 2. Rectangular area lights

Add an oriented, sized rectangle with radiance units, one-sided emission and a
bounded per-scene count. Integrate diffuse and glossy response over its solid
angle. Check orientation, distance, size, material response and camera-relative
coordinates. Document the shadow profile separately from illumination.

## 3. Compressed assets

Reuse the existing native meshopt, Draco and Basis work from the Zyren checkout
through narrow decoder interfaces. Adapt it to this worktree's loader and resource
contracts. Do not merge unrelated geospatial changes. Verify real fixtures,
malformed input, decoded allocation limits, cancellation and renderer cleanup.
Describe Basis transcoding separately from compressed GPU residency.

## 4. Geometry and controls

Add polygon shapes with holes, extrusion and useful topology utilities, followed
by trackball and fly controls through public input APIs. Check winding, normals,
degenerate input, bounds, picking, frame-rate independence and independent views.
Keep topology generation separate from GPU upload and Flutter gesture adaptation.

## 5. Temporal antialiasing

Expose bounded depth and motion information from the native scene stage. Capture
previous view, model, instance and deformation state only after an accepted frame.
Use subpixel jitter, reprojection, depth rejection, neighborhood clipping and
independent per-view history. Reset on cuts, resize, projection changes and device
reattachment. Check static convergence, moving silhouettes, disocclusion and cleanup.

## Qualification

Run focused regressions as each change lands, then the core, loader and Rust
suites. Run native pixel tests serially and Flutter presentation fixtures on the
available macOS and iOS targets. Update the gallery and capability matrix with
measured evidence. Platform compilation alone does not qualify a device. One
fresh-context reviewer checks the final diff and acceptance evidence.

Reference contracts: Khronos glTF material extensions and the Filament physical
rendering model. Keep the implementation split into focused material, lighting,
asset, geometry, control and temporal modules.
