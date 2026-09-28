# Section clipping

You can cut a scene with up to six world-space planes. A point stays visible
when its signed distance from every plane is nonnegative. Plane normals are
normalized, and offsets use the scene's units. Replacing `Scene.clippingPlanes`
invalidates the scene without changing geometry or transforms.

`Object3D.clippingEnabled` defaults to true. Setting it to false exempts that
object and its descendants. Transform handles opt out so you can still move a
selected part through the cut. Review pins follow their part's clipping state.

The native renderer applies the same planes to diffuse, unlit and standard
materials, including instances and shadow casters. Expanded lines and points
are cut across their rendered surface. Custom shader materials must opt out or
fail with an explicit unsupported error while planes are active. Arbitrary WGSL
cannot safely acquire a fragment discard without a shader contract.

Plane offsets are converted to camera-relative coordinates in Dart double
precision before upload. Binary scene opcode 28 carries the effective planes
with each mesh update. Removing a plane produces a mesh update too. Existing
packets remain valid and mean no clipping. Opcode 28 also carries an explicit
postprocessing flag, so a cut alone does not allocate HDR targets.

CPU triangle picking rejects intersections in the removed half-space and keeps
looking for deeper surfaces. Material sidedness still applies. These cuts do
not generate caps, change mesh bounds or modify exported geometry. Use a
double-sided material when you want to see a shell's interior.

The optional tools plugin owns a reversible section-plane session through the
public core API. It restores prior planes when disabled or detached only if its
last update still owns the scene state. External plane edits take precedence.
The workbench exposes one plane with an axis, signed offset and flip action.

Verification covers plane validation, scene invalidation, transformed and
instanced picking, camera-relative encoding, delta removal, malformed native
packets, and GPU pixels for built-in materials, primitives and shadows. Native
workbench checks cover the controls and desktop and narrow layouts. Surface
caps and custom-shader clipping remain separate work.
