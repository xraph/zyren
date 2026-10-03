# Scientific visualization

You can use the scientific package for scalar slices, isosurfaces, irregular
surfaces, vector glyphs, streamlines, temporal scalar data and native GPU volume
rendering. Metal on macOS and Vulkan on Pixel have numerical and Flutter
presentation evidence. Windows DX12 remains unqualified, and the shared Flutter
plugin currently has no registered Windows or Linux native presenter.

This chat owns `packages/zyren_scientific`, its package-local examples and this
plan. Shared edits use `/tmp/zyren-plugin-expansion.lock`; other owners' files and
staged changes remain untouched. No push or merge is authorized.

## Implementation decisions and status

| Area | Implemented behavior | Verification |
| --- | --- | --- |
| Scalars | Immutable float64 grids, validity mask, units/source identity, bounded allocations | Invalid input, affine values, missing versus zero, input mutation |
| Slices | X/Y/Z fractional planes, missing-cell holes, linear RGB transfer, local float32 error limits | Numerical fixtures, native colors, picks, registry commands and disposal |
| Isosurfaces | Six tetrahedra per cell, fixed body diagonal, shared edge vertices, low-side equality, increasing-value normals, stable cell IDs | Plane/sphere errors, closed manifold, winding, determinism, cancellation and budgets |
| Irregular surfaces | Validated triangle connectivity and vertex/cell scalar association | Missing triangles, invalid indices, degenerate input, source identity |
| Vectors | Immutable component grids, explicit right-handed orthonormal basis, trilinear sampling, bounded arrow glyphs | Basis transforms, missing/domain status, deterministic stride and budgets |
| Streamlines | Adaptive RK4 step doubling, length units, explicit step/error/stagnation/work limits | Constant, divergent and circular fields; deterministic stopping and cancellation |
| Time | Versioned ordered source frames, linear/discrete interpolation, two-frame cache, stale-load cancellation | Exact/interpolated missing data, cache reuse, failures, source/layout checks |
| Timeline | Optional `ScientificSliceTrack` using the shared timeline and stable scene parent | Atomic prepare, native seek, pause/detach demand release |
| Volume | Native RGBA32F 3D texture, manual trilinear sampling, opacity per reference length, HDR ray compositing, opaque depth and six clipping planes | Metal and Pixel Vulkan analytic fixtures, reversed depth, missing voxels, work limits and resource cleanup |
| Runtime agents | Shared field provider, rich source/units/time metadata, pick joins and authorized commands | Denial, grants, retries, stale state, cancellation, lifecycle tests and live stdio MCP |
| Flutter | Native lab with all representations, temporal seek, source picks, shared ZeroState and compact controls | macOS nativeView and Pixel sharedTexture, zero readback bytes; desktop/narrow layouts |

Streamlines follow a steady vector field by arc length. They are not pathlines
through evolving velocity data. Temporal scalar changes do not animate a separate
static vector field. The API and agent metadata retain that distinction.

Volume opacity uses exponential correction for step length. Rays stop at opaque
scene depth. Transparent surfaces and overlapping volume ordering are outside the
single-volume compositing contract. Float32 coordinate/scalar errors are checked
against caller tolerances; those tolerances do not certify measurement accuracy.

## Shared API audit and changes

The implementation reuses `GeometryData`, native line primitives, vertex colors,
`GpuScope`, sampled 3D float textures, `ShaderBindings` and the public HDR
postprocess depth interface. Camera-relative bounds preserve large world origins.
The core needed no scientific rendering extension.

The optional timeline adapter imports `zyren_timeline` through its public API.
The field and slice agent adapters use `zyren_agents`; examples reuse
`serveDevtoolsMcp` and `AgentDevtoolsBridge`. No independent protocol or network
listener was added.

Shared edits are additive: scientific package and package-local Flutter workspace
members, plus scientific's dependency boundary entry. Its production imports are
limited to `zyren`, `zyren_agents`, `zyren_timeline` and its own public package.
Native and devtools imports remain in tests/examples.

## Limits and qualification

Hard ceilings: 1,000,000 samples per scalar grid, 250,000 extraction/slice cells,
16 MiB conservative geometry payload, 20,000 glyphs, 100,000 streamline attempts
and points, two cached temporal source frames, and volume axes up to 256 samples.
Volume settings cap ray steps and viewport pixel-sample work before rendering.
Payload accounting excludes caller allocations, temporary copies, VM overhead and
native copies. Physical GPU residency was not measured.

The 35-test package suite and analysis pass. The sphere fixture's maximum radius
error is 0.008038175 m on a 0.125 m lattice, with a closed oriented manifold and
Euler characteristic 2. The circular streamline endpoint error is
3.403798572e-9 m. Metal and Pixel Vulkan volume fixtures agree within two 8-bit
values; owned native resources, shaders and materials reach zero after teardown.

See [package qualification](../../packages/zyren_scientific/qualification/2026-10-02.md)
for the device matrix, numerical values, commands and evidence locations. GPU
readback checks, Flutter presentation and direct UI inspection are separate
results. The lab has no browser or readback fallback.

## Commit state and remaining limits

Earlier local commits: `5f38906` scalar slices and runtime tools, `ef3234c`
checkpoint evidence, `72406a0` bounded surfaces, `e44a04c` vectors/streamlines,
and `3352fb1` temporal sources/shared timeline. `bcd93d9` adds native volume rendering, field commands, the Flutter lab and
qualification evidence. All commits are local on `main`.

The requested scientific representations have implementation and available-device
checks. Windows DX12 numerical qualification still needs a Windows machine.
Windows/Linux Flutter presentation also needs a shared platform presenter; runner
scaffolding alone does not supply one. Other chats currently own the connected
iOS sessions, so this workstream does not claim iPhone/iPad qualification.
Comprehensive accessibility, undo/history integration and publication are not
established by these rendering checks. Nothing has been pushed or published.

The final workspace package boundary check passes. The point-cloud workstream
resolved the unrelated imports reported by the earlier run. Scientific analysis
has no diagnostics. The timeline adapter also rejects time spans that collapse
below its microsecond clock precision, with a focused regression check.

Pixel follow-up, 2026-10-03: the awake-device rerun passed three numerical/lifecycle
tests and presented all six modes through `sharedTexture` with zero readback bytes.
The final Flutter test stopped making progress after the volume marker while the
screensaver, Reality Capture and Planet took the foreground. This workstream's
test was interrupted; Flutter's zero exit code accompanied shutdown errors and
does not count as a pass. The newest agent-pick/source-cell join passes on macOS
and still needs an exclusive Pixel window with Scientific Lab visible. Device
coordination authorization was requested. The Windows-host question remains open.
See the qualification report for this attempt's log and source hashes.
