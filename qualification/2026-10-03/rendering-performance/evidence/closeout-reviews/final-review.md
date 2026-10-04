# Final rendering review

## Scope and verdict

**Specification verdict: partially satisfied. Quality verdict: changes required. Ready to merge: No.** The implementation covers the planned architecture and has substantial native shader and integration evidence. Three owned integration defects remain. The requested foreground smooth-navigation outcome also remains unqualified, independently of those defects.

Reviewed the committed plan, final dispatch/context, exact owned chronological source package and index, ownership manifest, relevant task reports, final source, and selected raw qualification data in bounded thematic passes. Base: `e775e0ae`. Final owned reviewed head: `b38fb4d604c6975ca75185be07695f47a736004f`. The 42-chapter source package is 1,995,637 bytes, SHA-256 `ed5681990ceb0306bca5c742ec98d81b7ea04d5e932fbcc570c9c8b44ca906e3`. The 9,548,862-byte exact package additionally contains evidence. The broad shared-main range is not the attribution boundary. The mixed `68e4744f5d06a73ec04bff23eb2fdd59c8101622` chapter was limited to its 27 positively owned paths.

Current-source line numbers below refer to the inspected checkout, most recently at `fd62a4bae1911c1e22b3be1a54da02de94556a4e`. Current main has concurrent changes. Where later source changes affect a finding, that provenance is explicit. Source, index, HEAD and branch were not mutated. No subagents or new test runs were used. Only this ignored report was written. Existing suite outputs were checked as evidence rather than rerun.

## Strengths

- The separation of candidate admission, submitted/displayed cover and retained reprojection is coherent. Publication identity reaches picking and attribution; old frustum omissions are restored during reprojection. The optional horizon/motion policy stays outside generic rendering, and ambiguous bounds remain conservative.
- Queued graph work, bounded writes, completion-aware retirement and all-view binding invalidation are substantially developed. The draw-cache reclaim path accounts for uniquely reclaimable completed resources. The issue below is a remaining whole-frame transaction boundary, not a rejection of that ownership model.
- Cloud requested, prepared, submitted and displayed state have separate publication points. Adaptation requires supported complete scene GPU samples, and missing timing is not treated as zero. Shadow reuse is guarded by media and cascade stability. Prepared atmosphere resources are guarded against mismatched engine/frame use.
- Batching has conservative overlap/order barriers and explicit exclusions. The mapped-PBR regression checks actual automatic batching, an unbatched ordered reference, presented identity and exact whole-image equality. Probe assignment is the missing compatibility dimension.
- PBR work has real shader coverage, independent compensated-energy reference calculations, coherent table endpoints, material-map checks and derivatives evaluated before divergent discard. Approximation and cold table cost are documented rather than described as exact physical parity.
- Forward SSR/AO has a distinct unmodified source, selected-environment fallback, bounded settings and explicit capability limits. It does not claim generic MRT or temporal accumulation. Capture/probe leases have separate view/admission identity and cleanup paths.
- Qualification distinguishes source changes, tests, loaded artifacts, presenter evidence and failed foreground attempts. Capability/parity/rendering snapshots match the canonical documents, and the chronological decisions retain costs and limits.

## Issues

### Critical

None established.

### Important: owned changes

#### O1. Automatic batching ignores per-object local environment selection

**Priority: P1.** `packages/zyren_native/native/src/renderer/batching.rs:215`, `:296`; binding consequence at `packages/zyren_native/native/src/renderer.rs:1231` (owned-head line 1226).

The batch candidate compares normalized `Mesh` values, geometry/resources, camera and three render settings. Local environments live separately in `frame.settings.local_environments`. Neither the grouping condition nor the retained batch-plan key includes the resolved environment assignment. Rendering binds `environment.for_mesh(index)` once for the batch leader, so every automatically instanced object receives the leader's environment.

Minimal trigger: two otherwise batch-compatible, nonoverlapping objects share geometry/material/order, while one selects a local probe and the other selects the global environment or a different local probe. The batch uses one object's diffuse/specular environment for both. An SSR miss can therefore fall back to the wrong probe. Moving or reprioritizing a probe with unchanged meshes/camera can also reuse a previously valid batch after assignments diverge.

Fix: include resolved environment identity in compatibility and retained-plan validity, or make differing assignments batching barriers. Assignment changes must invalidate the plan. A texture update under an unchanged shared assignment need not split the batch, but it must still refresh the actual environment binding through normal resource invalidation.

Missing coverage: render objects across local/global and two-local-probe boundaries, compare the entire image against a deliberately unbatched reference, and assert a positive batch count for same-environment controls. Repeat after changing probe selection without changing meshes or camera. `packages/zyren_native/test/reflection_probes_test.dart:66` uses a single test mesh. The mapped-PBR batching fixture does not contain competing probe assignments.

#### O2. Late pipeline rejection leaves dynamic patch bases mutated and removed

**Priority: P1.** `packages/zyren_native/native/src/renderer.rs:889`, `:904`, `:1920`, `:1948`; `packages/zyren_native/native/src/renderer/instances.rs:132`, `:159`.

Both presentation and readback preparation upload scene assets before fallible pipeline preparation, then commit scene publication only after pipelines succeed. In the common unstaged dynamic-update path, `prepare_scene` allows geometry/instance reuse when no other view or staging owner retains the base. The patch mutates the existing GPU allocation and replaces the base ID in the native map. A later pipeline union-cap rejection or recoverable pipeline creation failure leaves the view and Dart encoder on the old accepted revision, but its native patch base is gone.

Minimal trigger: accept dynamic geometry or instances, update a range in a packet that is small enough to avoid staged admission, and make that same frame fail pipeline preparation. The old displayed publication remains logically current. A corrected retry still patches from the old accepted base, which native decoding can no longer resolve.

There are two consequences to distinguish. First, reuse writes new bytes into the old GPU allocation before rejection: `resources/runtime/scene_updates.rs:58` selects the old buffers and submits the copies before returning; `resources/runtime/instances.rs:73` does the same. Second, `renderer.rs:904` and `renderer/instances.rs:159` remove the old map IDs. Restoring only map membership would not restore the accepted contents because the reused allocation has already changed. The non-reuse path preserves the base allocation, so it does not have this particular in-place corruption; it still needs staged candidate cleanup after rejection.

The owned pipeline preflight provides a concrete newly recoverable late rejection path, including the 512-pipeline/128-layout caps. Its internal transaction preserves the pipeline cache, but does not roll back earlier scene preparation. `ScenePacketEncoder.reject` preserves the last accepted upload baseline, as it should, and therefore exposes the mismatch on retry.

Fix: complete fallible preflight before destructive resource/cache changes where possible, and stage replacement versions until the whole frame can commit for remaining failures. Preserve old IDs and old bytes until acceptance. Include candidate cleanup and batch/draw-cache state in the transaction rather than patching only the missing map entry.

Missing coverage: drive the full render path with accepted dynamic geometry and dynamic instances, force a later pipeline cap or injected creation rejection, verify old publication/resource contents, then retry a corrected frame through the same encoder without resetting it. Cover both reused and separately owned bases. `pipelines.rs:660` and its cache-churn tests invoke pipeline preparation directly. The impossible-overlap fixture in `test/scene_admission_test.dart:245` rejects static new geometry before upload; the staged cross-view patch fixture protects another owner but does not reject after a dynamic upload. `native/tests/draw_preparation.rs:341` tests cache admission, not this pipeline/patch interaction.

#### O3. Prefetch can consume the decoded-memory headroom needed by visible work

**Priority: P1.** `packages/zyren_3d_tiles/lib/src/streamer.dart:668`, `:677`, `:692`.

The request-count allowance leaves a slot for visible work, but speculative admission uses the same decoded-byte capacity check without leaving a visible request's byte reservation. Visible work is iterated first only when the pump starts requests. A previously admitted slow prefetch can reserve the remaining bytes before the camera selects a new visible tile.

Minimal trigger: let `P` be `perTileDecodedBytes`, set the decoded cap to `2P`, retain displayed content of size `C` where `0 < C <= P`, and start one gated offscreen prefetch reserving `P`. A new visible request requires `C + 2P`, which exceeds the cap, even with `maxRequests = 2` and `maxPrefetchRequests = 1`. Without that prefetch, `C + P` fits. The old complete cover correctly cannot be evicted. If camera movement cancels the prefetch, the physical request still owns its reservation until `tracker.drain` completes, so cancellation alone does not restore visible priority.

This makes visible replacement latency depend on speculative I/O under memory pressure, contrary to the plan's separate bounded allowance and visible-priority requirement. It does not imply a memory-cap overflow or incorrect old-cover eviction.

Fix: reserve usable decoded-memory headroom for visible admission before starting speculative work, and apply the same reasoning to resident-byte reservations. Disable prefetch when that slack is unavailable. Preserve physical cancellation/drain accounting rather than releasing live reservations early.

Missing coverage: retain a complete cover near a tight byte limit, gate a prefetch resolver, select a new visible tile, and assert its resolver begins before the prefetch gate opens while every budget counter stays bounded. The cancelled-prefetch test at `packages/zyren_3d_tiles/test/motion_test.dart:185` provides ample default decoded capacity and tests request-slot priority, not byte-pressure priority.

### Important: concurrent integration findings for controller adjudication

These two triggers require the later concurrent commit `4dc28ec333fc8de822d3921b889748620b17f241`, `feat(rendering): scale native opaque scene capture`. That commit adds the public scale in `packages/zyren/lib/src/rendering/postprocess.dart`, scaled targets in `packages/zyren_native/native/src/renderer/transmission.rs`, and the capture-only viewport change in `renderer.rs:1082`. They are not attributed as owned-head regressions. At the owned head, the relevant source/capture extents match. The owned side is the Task8c source/capture binding scheme and screen-lighting shader shown below.

#### C1. Source and scaled capture overwrite the same per-mesh uniform buffer

**Priority: P2.** Current `packages/zyren_native/native/src/renderer.rs:1218`, `:1265`, `:1299`; owned side is `UniformKey::Mesh(index, capture)` and separate source/capture binding creation, already present at the reviewed owned head.

Screen-source bindings are made with `(capture=true, screen_source=true)` and transmission bindings with `(true, false)`. Both use the same retained uniform key. With capture scale below one, they now contain different viewport sizes. The later capture upload overwrites the buffer referenced by the source bindings before command submission.

Minimal trigger: enable screen lighting, require an opaque transmission capture at scale 0.5, and include opaque pixel-unit points or lines. The full-size source pass sees the half-size viewport; `renderer/primitives.wgsl:51` and `:74` use it for screen-space geometry, altering footprints in source radiance/depth. This can corrupt later SSR/AO input even though the ordinary main pass has its own key.

Fix: distinguish main/source/transmission uniform identities, updating retained-cache planning, byte accounting and retirement, or prove equal immutable bytes before sharing. Missing coverage: compare source point/line footprints at scale 1 and 0.5 with both passes active, then verify warm-cache reuse and retirement. The scale-only transmission fixture does not exercise this combination.

#### C2. AO samples full-size source depth using scaled-capture pixel coordinates

**Priority: P2.** `packages/zyren_native/native/src/renderer/pbr.wgsl:109`, `:122`; `packages/zyren_native/native/src/renderer/screen_lighting.wgsl:18`.

The owned AO shader passes raster `input.position.xy` and the current raster's world-per-pixel derivative directly into a full-resolution source-depth lookup. Concurrent capture scaling makes the effect-enabled opaque transmission pass use a different pixel grid. A half-size capture fragment at x=24 represents source x=48, but AO samples around source x=24; its projected radius also uses the wrong grid. This survives a fix to C1.

Minimal trigger: AO, scale 0.5 and an off-center occluder/receiver visible through transmission. The captured background loses or shifts its occlusion because it samples the wrong source neighborhood.

Fix: derive source UV from projection or transform both pixel location and footprint into source texture coordinates using actual pass/source extents. Missing coverage: an off-center AO fixture behind glass at two capture scales, comparing corresponding world locations with a reference and reasonable resampling tolerance. Verify direct/emissive lighting remains unaffected. Do not silently disable the requested effect to hide the mismatch.

### Minor and deferred dispositions

1. **Atmosphere close allocates replacements that it immediately discards.** `packages/zyren_geospatial/lib/src/atmosphere/plugin.dart:808` calls `_changeCloudInputs(null)`, whose replacement path rebuilds pending prepared tokens, then `:809` closes those tokens. Confirmed avoidable allocation and transient peak pressure; no leak established. Keep as Minor. A close-specific path should preserve transaction/error semantics without rebuilding doomed tokens. A focused allocation/close test would distinguish this from a leak claim.
2. **Transmission guard assertions are not isolated.** `packages/zyren_native/native/src/renderer/transmission_tests.rs:112` leaves sample count at four before the format/depth assertions at `:120`. Both can pass due to MSAA regardless of their intended guard. Keep as Minor coverage debt. Reset to a known reusable single-sample baseline, assert it is reusable, and vary only format or loaded depth per case.
3. **Glossy threshold inequality does not isolate source taps.** `packages/zyren_native/native/src/renderer/screen_lighting_tests.rs:315` changes material roughness from 0.05 to 0.0501, then `:339` attributes any image difference to the cone footprint. BRDF changes can independently satisfy the assertion. Keep as Minor coverage debt. Instrument source loads or compare controlled forced tap paths with identical shading inputs. The separate exact seeded-capture/redraw equality assertions remain useful.
4. **Twelve raw PPM fixtures lack binary attributes.** Qualification fixture paths under `qualification/2026-10-03/rendering-performance/` have unspecified Git text/diff attributes; ordinary review tooling can misclassify bytes. Keep as Minor tooling debt. Add qualification-local `*.ppm binary` attributes, preserving file bytes/hashes. The per-command binary treatment used for the exact review package preserves this package but does not fix ordinary tooling.
5. **Dependency/SPM/Flutter Assemble notices and foreground failure.** Final qualification records the notices and failed foregrounding, rather than claiming they disappeared. Dependency/toolchain warning cleanup is a follow-up, not an established rendering defect. Foreground failure remains an unmet live qualification condition, not a waived test or a source-code failure inferred from a warning. `restoration.json` records ordinary binding restored and a visible city, but explicitly leaves physical gesture and sustained foreground verification false.
6. **Earlier mapped-PBR batching finding: addressed.** The final fixture checks positive automatic batching and a zero-batch ordered reference with exact pixels and identities. Preserved arrays are both 97,364 bytes with SHA-256 `7697e10e13c54b4032c299be2ee4c7166addd954b0a7a2886d0157cb98afd2d0`; profiles show one batch/four source meshes versus zero batches/four draws. This closes that earlier finding. It does not close O1.

## Evidence and test-oracle review

Read-only inventory verification found all 897 stored files and their source forms consistent with recorded lengths and SHA-256 values, totaling 20,851,295 stored bytes. The canonical capability, parity and rendering documents match all three committed snapshots. The durable ownership manifest has 41 preceding owned commits; the scratch review manifest has 42 including the final evidence commit. That difference is expected rather than missing source attribution.

The six large-world AO/SSR stationary and retained-frame numeric image comparisons were inspected: each is 96x96 RGBA, with zero differing bytes and maximum difference zero. The origin is `[6378137, -4194304, 2097152]`. Retained cases explicitly have candidate readiness false. This is useful reprojection/rebasing evidence, not a live globe coverage test.

Preserved final outputs report Rust library 49 passes, native 248, core 796, tiles 91, Flutter 174, and geospatial 359 with 19 skips. These are historical reported runs, not new executions at the current moving HEAD. Initial failures remain separate from superseding final runs.

Task9 oracle changes are supported by the final behavior: additive nullable profile fields; timing storage derived from named slots with absent/incomplete checks; cold energy-table draws distinguished from warm mesh draws; a separate high-sample compensated-PBR reference retaining color/map semantics and tolerances; codec waits bounded by request quietness plus displayed identity; and the focused Flutter readiness predicate retaining initialization/failure/closed guards and independent visible-host scheduling. The original borrowed-remount expectations remain. The fake loaded model explicitly uses the material capability its fake backend supports and still asserts readiness.

The final route collector checks accepted-presentation liveness and accepted source frames on both sides of reversal. The earlier early-only reversal acceptance weakness is addressed in source and focused evidence. It is not foreground-qualified by the failed schema-2 live attempts.

The first live attempt contains 34 accepted stationary frames spanning about 2.968 seconds and remains `completed=false`; the second has no completed phase data. The first reports frame interval p50/p95/p99 of 85.245/138.774/146.231 ms and scene GPU 9.959/17.82/34.638 ms. Those are incomplete stationary diagnostics, not successful route FPS. It reports zero readbacks and zero backlog, while all 34 frames are tile-budget limited. Visible/displayed counts do not prove complete geometry coverage. Auto was requested/applied and sampled cloudAdaptive.sceneGpuTimeNs values are populated. The retained policy reason timingUnavailable does not establish that current scene GPU measurements were absent or stale. No adaptive quality transition was established. Named GPU pass timings, registry bytes and physical residency remain null where unavailable.

The final documentation accurately retains these limits. The native framework and host executable hashes were captured before and after the live attempt and were unchanged. Only the Dart AOT identity was observed later during restoration; that later observation does not establish a contemporaneous AOT identity for the attempt. Synthetic shared-host comparisons are diagnostic only; they do not supply a matched Planet baseline or an improvement percentage.

## Recommendations

Fix O1 through O3 in a focused wave with the interaction tests described above, then review the changed transaction, cache and admission boundaries together. Keep C1 and C2 separately attributable while the controller decides whether to include compatibility fixes. Isolate the two weak shader/guard tests and add binary attributes in small changes. The atmosphere close optimization is lower priority than correctness.

Preserve the current qualification language until a foreground route actually completes with the intended artifact, camera phases, coverage observations and timing support. A passing code fix does not retroactively change the failed live result. No broad suite rerun was needed to establish these static findings; focused regression tests are needed to verify fixes.

## Declined to judge

- Sustained foreground Planet smoothness, motion grain, rotation/drag/zoom/reversal performance and physical camera gestures: no completed foreground route or gesture verification exists in the preserved live attempts.
- Complete live-provider geometry coverage and behavior under unobserved provider/network conditions: selected/displayed counts and retained-cover fixtures do not prove completeness of the actual world.
- A Planet FPS improvement percentage: no matched before/after baseline with comparable scene, host load and artifacts exists.
- Actual Auto cloud quality transitions during live navigation: the run was incomplete and demonstrated no transition. Populated scene GPU samples coexist with the retained timingUnavailable policy reason, which does not independently establish current sample absence or staleness.
- Non-Metal platform parity, mobile sustained performance, thermal behavior and the combined renderer on Vulkan/DX12 hardware: device evidence is absent for this final combination; compilation and isolated tests are not substitutes.
- Physical GPU residency and individual native Metal pass GPU costs: the corresponding measurements remain unavailable/null. Registry accounting and scene-total GPU timing are different quantities.
- Real allocation exhaustion, physical device loss and real presenter timeout recovery: budget rejection, controller injection and worker abort fixtures do not exercise those physical faults.
- Pixel-level parity with an external renderer or exact reciprocal multiple-scattering physics: the implemented compensated PBR approximation is documented and tested against its own independent reference; no external parity capture was supplied.
- Generic MRT, temporal reflection accumulation and off-screen SSR reconstruction: these are outside the approved forward screen-lighting design and are not claimed as implemented.
- Dynamic edits beyond PublicationGroup's documented membership/publication contract: the reviewed snapshot mechanism does not claim arbitrary mutation isolation of all referenced user objects.
- Performance implications of the deferred atmosphere allocation under a real low-memory device: redundant allocation is confirmed, but no leak, OOM incidence or measured peak regression is established.
- Whether C1/C2 compatibility fixes belong in this task's ownership: their current trigger comes from the separately identified concurrent scale commit. Their correctness impact is assessed above; ownership is for the controller to adjudicate.
- Unrelated concurrent scientific, navigation, physics, AI, manifest, package-boundary and example work: outside the positive owned-path boundary, except the explicitly inspected capture-scaling interaction.
- Dependency upgrade necessity, SPM migration, Assemble-script cleanup and unrelated toolchain warnings: no concrete owned rendering malfunction was established from those notices; retain them as recorded follow-ups.
- Earlier tests lacking contemporaneous loaded-library hashes: useful scoped test evidence, but insufficient for a stronger source-to-loaded-artifact claim after the fact.
- Website documentation import/publishing and deployment readiness: canonical local snapshots were checked; no website publication or deployment was part of this read-only review.

## Assessment

**Ready to merge: No.** The main design and evidence discipline are strong, but local-probe batching, dynamic-update recovery and prefetch byte priority violate important integration contracts. Fix those owned defects and adjudicate the two concurrent scale interactions; separately, keep the requested live navigation outcome explicitly unqualified until the foreground route succeeds.
