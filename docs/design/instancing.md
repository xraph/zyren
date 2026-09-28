# Instanced meshes

Use `InstancedMesh(geometry, material, count: n)` to draw repeated triangle
geometry with a shared built-in material. `setTransform(index, matrix)` updates
one local transform. `transformAt(index)` returns its immutable matrix. Counts
are fixed for the life of the object, from one to 65,536. A view admits at most
65,536 instances in total. Custom mesh shaders and line/point primitives remain
outside this profile.

Each slot has a stable `PickResult.instanceIndex`. Picking applies the parent,
mesh and instance transforms, respects material sidedness and shares the geometry
BVH across slots. Results retain the scene revision and hit coordinates from the
query. They keep their slot identity when native draw order changes. Instance
bounds are tested through local rays; there is no separate instance-level BVH.
The tools package's object selection and transform gizmo still act on the whole
mesh. You can use the returned slot to build an instance editor.

Camera-origin subtraction happens after double precision transform composition.
Native instance records contain a float32 model matrix and inverse-transpose
normal basis, 112 bytes per slot. A view owns its buffer. An unchanged view reuses
it; edits upload contiguous changed records. Earlier captures in another view
retain their values. Scene packets currently transfer the changed mesh's complete
matrix array, while GPU writes update only changed records.

Opaque instances group by winding so negative scales use the correct culling
pipeline. Transparent instances sort by projected bounds-center depth together
with other transparent meshes. Adjacent compatible instances share a draw.
Equal-depth transparent slots retain their original order. This is ordinary
sorted transparency: intersecting surfaces still need an application-specific
ordering policy. Instanced normal maps, authored tangents, directional cascades,
spot shadows and alpha-masked casters use the same material rules as `Mesh`.

Instance buffers share a separate 64 MiB device budget across views. Admission
precedes view replacement. Exceeding it leaves the earlier view usable; closing
a view releases its allocation. `GraphCacheStats.instanceBytes` reports current
residency and `instanceUploadedBytes` counts cumulative writes. `instanceDrawCalls`
counts the current instance batches across prepared views, excluding shadow
projections. Frame draw counts derive from the captured scene's ordering; they
exclude shadow passes and fullscreen effects.

Core fixtures cover stable picking slots, Earth-scale origins, immutable captures,
invalid transforms and 10,000 distinct transforms. Metal fixtures compare
instances with ordinary meshes, including mirrors, transparent overlap, tangent
normal maps, shadow masks, dirty uploads, shared budgets and view teardown.
The complete core suite has 393 tests; the native Dart GPU suite has 59. Rust
GPU tests, strict Clippy, analysis and package boundaries pass. Mobile instance
qualification remains part of the final renderer checks.

You can run `dart run tool/instance_benchmark.dart` from `packages/zyren_native`.
The recorded macOS JIT probe renders 10,000 distinct transforms at 128 by 128:
capture takes 5.7 to 7.3 ms and the full readback call takes 14.0 to 21.1 ms across
eight measured samples after four warmups. It uses one draw and 1,120,000 instance
bytes. A single edit writes 112 bytes; removal leaves zero instance bytes. These
times include explicit readback and JIT execution, so they do not establish native
presentation throughput. The fixture records backend, host, timings and cleanup
at [the benchmark checkpoint](../../benchmarks/renderer/instances-macos-jit.json).
