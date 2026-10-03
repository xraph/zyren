# Reality capture: point clouds and Gaussian splats

This work owns `packages/zyren_pointclouds`, `packages/zyren_splats` and their
package examples. Neither package is published. The requested completion scope
covers streaming/LOD, LAS/LAZ/E57, perspective splats, scene compositing, geospatial
adapters, live MCP and mobile qualification.

## Current implementation

| Workstream | Implemented behavior | Evidence |
| --- | --- | --- |
| Point ingestion | Strict XYZ and bounded native LAS/LAZ/E57, float64 coordinates, original ordinals, immutable source attributes and metadata | Real encoded synthetic fixtures; native Rust and Dart tests; Metal and Pixel imports |
| Streaming/LOD | Frustum and screen-error selection, ancestor fallback, independent payload/cache/request budgets, cancellation through drain, stale-result disposal, eviction and explicit retry | Transition tests, filtered source queries and native streamed scenes |
| Gaussian sources | Positive-definite covariance, bounded 32-byte `.splat`, explicit linear/sRGB conversion, source identities through chunk merges | Malformed/budget tests and numerical covariance checks |
| Perspective splats | Perspective Jacobian, stable CPU mean-depth order, near/far mean clipping and a configurable scene variance floor | Finite-difference Jacobian and native Metal/Vulkan pixels |
| Scene compositing | Public mesh shader, opaque scene depth test, premultiplied blend, transforms, visibility and section planes | Native pixel occlusion, clipping, transforms and resource cleanup |
| Geospatial | Declared ECEF/ENU/affine source mapping; shared reference frame for scene placement and source evidence | Geodetic round trip and original-source ray query |
| 3D Tiles | Live loading/LOD/budget context; declared tile associations verified against resident feature identities and properties | Loaded B3DM feature properties, missing/evicted mappings and revision guards |
| Agents and MCP | Shared registry, viewport context, source-aware point and Gaussian queries, scoped point filter/undo/retry | Registry tests and live shared stdio MCP, including denial, identical retry, stale revision and EOF cleanup |
| Native qualification | macOS Metal and physical Pixel 9 Pro Vulkan | Package and Flutter integration checks; desktop and narrow visual review |
| iPhone | Unsigned device build succeeds; signed deployment blocked | Apple App ID quota and missing app provisioning profile, unchanged after unlocking |
| iPad | Wireless deployment reaches signing; device tests blocked | Same App ID quota and missing profile; `flutter drive --publish-port` supports the wireless test path |

The detailed platform record is
`packages/zyren_pointclouds/qualification/2026-10-03.md`. It separates actual pixels,
normal native presentation, CPU queries, compilation and unverified platforms.

## Decisions and public contracts

The audit found native `PointGeometry`, `PointsMaterial`, core asset loading and
scoped GPU ownership. Core triangle ray queries do not cover source points or
Gaussian opacity. Both packages therefore retain their own bounded source queries
while using the shared scene graph and agent viewport contract.

A source record is `(sourceUri, sourceVersion, recordIndex)`. Runtime object IDs do
not replace it. LOD retains original point samples and Gaussian records. Invalid
E57 records leave gaps in source ordinals; local array indices remain separate.
Point rendering uses recentered float32 positions with a declared error limit,
while source queries retain float64 coordinates. This does not establish survey
accuracy or infer a measured surface from marker pixels.

Native LAS/LAZ/E57 decoding is package-owned Rust with pinned dependencies and
licence notices. The Dart worker checks cancellation between records and drains
before native job destruction. Section lengths, declared counts, LAZ chunk tables
and layered buffers are checked before allocation. WKT, LAS scale/offset, E57 scan
poses, attributes and scan identities remain available. LAS waveform references
are retained, but waveform sample payloads are not decoded. Chunked LAZ requires
a valid chunk table.

The generic streamer lives in `zyren_pointclouds/streaming.dart`; splats reuse it.
You can provide an asynchronous storage/network chunk loader. Offline octrees are
bounded preprocessing helpers and retain their own source copies. Evicting a
streamer entry does not release data retained by those builders. Payload budgets
exclude Dart object, native parser and renderer-cache overhead. Physical GPU
residency remains null.

Gaussians join scene rendering through public mesh shaders. No shared renderer
change was needed. Each visible cut uses one combined CPU sort, avoiding separate
tile draw order. The shader depth-tests at the mean and does not write scene depth.
Opaque occlusion is qualified. Intersecting Gaussians and transparent mesh order
remain approximate; Gaussian estimates are appearance evidence, not measurements.
The explicit offscreen renderer remains color-only and owns per-frame targets.

## Agent and domain integration

Both packages use `zyren_agents` and `AgentViewportProvider`, with bounded schemas,
source/runtime IDs, camera/frame guards and lifecycle-bound registrations. Streamed
queries follow the current visible cut. Missing rendered-pixel coverage stays
unknown, including occlusion and clipping in Gaussian CPU estimates.

Point commands require host-granted scopes, expected revisions and idempotency
keys. Filter undo checks that the host has not replaced the original command's
result. Retry calls the ordinary stream loader. No command bypasses the registry.
The example host uses the existing `zyren_devtools` stdio transport and adds no
independent MCP protocol or network endpoint. It unregisters scene providers and
drains both streams on EOF.

Geospatial imports are optional entry points. Declare the source transform; a WKT
string alone is not a conversion. Arbitrary reprojection and geoid correction
remain host responsibilities. Tile feature context requires an explicit source
association and a matching resident feature. Missing or ambiguous associations
stay unverified. Feature property output has a 16 KiB ceiling.

Shared dependency edits add `zyren_pointclouds` to splats and the optional domain
adapters' `zyren_geospatial`/`zyren_3d_tiles` dependencies. The qualification app is
one workspace member. Boundary and index edits use the shared lock, preserving
other owners' entries. No production core renderer or native backend files belong
to this change.

## Lifecycle and qualification boundaries

Scene plugins close their streams on detach by default. Hosts that retain source
streams during engine or plugin recreation can opt out and own final closure.
The qualification app uses that model and disposes its retained streams after the
controller drains. The Gaussian renderer recreates its attachment scope and GPU
resources when reattached. Forced physical device loss is not a qualified scenario.

macOS Metal and Pixel Vulkan are separate evidence. iPhone and iPad deployment are blocked
by the current signing account's maximum of ten new App IDs per seven days and no
profile for this app. Unlocking the phone does not resolve that account limit.
An unsigned iOS build succeeds, but cannot establish on-device rendering. The iPad
retry used `flutter drive --publish-port` over Wi-Fi and reached the same signing
failure. Windows/DX12 and Linux GPUs remain unverified.

Higher-order spherical harmonics, PLY import, GPU sorting and large-dataset
performance qualification remain future work. This completion run does not claim
full 3DGS format parity, universal mobile coverage or readiness for every platform.
The standalone MCP AOT experiment failed native startup; `dart run` is the verified
host command.

## Local commits

- `8ef7820`: initial XYZ, native markers, orthographic offscreen Gaussians and shared providers.
- `a95143c`: native LAS/LAZ/E57, immutable attributes and encoded fixtures.
- `dc5cbfe`: bounded spatial streaming and source-preserving point LOD.
- `f2b6ee6`: perspective Gaussian scenes, streamed providers, format and geospatial adapters.
- `4637d07`: fresh Gaussian attachment scopes and repeated native resource cleanup.

Qualification and lifecycle follow-ups stay in focused local commits. Nothing is
pushed, merged or published by this task. Checks ran in the concurrent workspace;
they do not certify unrelated owners' changes as a release.
