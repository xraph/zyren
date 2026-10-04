# Spec Compliance

- ✅ Spec compliant for the scoped fix round. Both original Important findings are ADDRESSED. No new Critical or Important defect found in the fixes.
- ⚠️ Schema 3 has focused test evidence only. The preserved live records remain failed schema 2 attempts with zero completed phases; foreground/device qualification and the separate whole-change review remain open (`qualification/2026-10-03/rendering-performance/live-navigation.md:3`).

# Original Findings

## Important 1: ADDRESSED

The original finding in `task-9-review.md` states that a reversal can be marked completed without executing or presenting the reversal, and that early-only samples omit the stalled tail from throughput.

- The harness now waits for an accepted receipt at or after 12,000,000 microseconds and rejects a live receipt gap above one second. Post-phase validation checks initial, interior and terminal gaps, rejects early-only samples, and requires the terminal receipt to cross the boundary (`examples/planet/lib/google_navigation_benchmark.dart:382`, `:404`; `examples/planet/lib/navigation_benchmark_route.dart:31`). This matches approved Ruling 49, including rejection of a run that later recovers from a longer gap.
- An applied reversal requires the actually issued wave to decrease at or after six seconds. Validation requires at least two accepted samples on each side, increasing then decreasing command values, and a finite negative dot product between the two actual camera displacements (`examples/planet/lib/google_navigation_benchmark.dart:370`; `examples/planet/lib/navigation_benchmark_route.dart:50`, `:54`, `:86`). A missing command, an unpresented command, unchanged pose or continuing forward motion cannot satisfy these checks.
- The historical handoff latches command state for the preparing frame and stores a pose only when the submitted camera identity/revision still matches. Accepted receipts consume records using frame ID, camera revision and camera runtime ID; records are bounded to two and cleared at phase transitions and detach (`examples/planet/lib/navigation_benchmark_route.dart:97`, `:134`, `:140`, `:168`; `examples/planet/lib/google_navigation_benchmark.dart:287`). Unmatched receipts remain unknown rather than inheriting the latest command.
- The schema 3 caller always supplies the stopped Stopwatch duration. Throughput uses receipt count over the entire measured window, while first-to-last receipt span, initial delay and terminal gap remain separate (`examples/planet/lib/google_navigation_benchmark.dart:439`; `examples/planet/lib/navigation_benchmark_stats.dart:64`, `:72`, `:77`). A known empty interval reports zero observed throughput with GPU measurements still null.
- The tests cover early-only and missing terminal receipts, initial/interior/terminal gaps, absent and delayed-unpresented reversal, unknown/unchanged/continuing camera motion, exact gap boundaries, source mismatch and full-duration accounting (`examples/planet/test/navigation_benchmark_route_test.dart:101`, `:123`, `:140`; `examples/planet/test/navigation_benchmark_stats_test.dart:5`). The lifecycle test exercises the real SceneEngine hook pipeline, a later camera/clipping hook, historical command preservation, plugin removal and backend cleanup (`examples/planet/test/navigation_benchmark_route_test.dart:18`).

## Important 2: ADDRESSED

The original finding in `task-9-review.md` identifies stale instance, screen-effect and explicit-resource limits in the capability snapshot, plus ambiguous attribution of older platform qualification.

- The canonical source and durable snapshot now state 100,000 instance slots, 32 custom screen effects, a 64 MiB per-allocation limit and a configurable 256 MiB shared device default. They distinguish the registry from internal attachment budgets and physical residency (`qualification/2026-10-03/rendering-performance/documentation/renderer-capabilities.md:10`, `:11`, `:16`, `:18`). The 16 MiB to 1 GiB range agrees with configuration validation; the native per-buffer/texture checks retain the 64 MiB limit (`packages/zyren_native/lib/src/resources.dart:211`; `packages/zyren_native/native/src/resources/upload.rs:4`, `:130`, `:183`, `:196`). The instance/effect enforcement was verified in the original review and is unchanged by this fix.
- Historical platform rows are explicitly labeled earlier scoped evidence and do not qualify the October combined artifact (`qualification/2026-10-03/rendering-performance/documentation/renderer-capabilities.md:102`). The canonical source, snapshot and refreshed SHA256 all match (`documentation/sources.json:5`). No website import or deployment is claimed.

# New Breakage

- Critical: None found.
- Important: None found.
- Minor: No new actionable finding within this fix scope. Dependency-update notices remain in `qualification/2026-10-03/rendering-performance/evidence/task-9-validation/fix1/benchmark-final.log:21`; they were already disclosed and deferred, not introduced by the implementation.

# Verification and Focused Integration Checks

- Read the unchanged brief, both original Important findings verbatim, appended Fix round 1 report and exact fix package for `b38fb4d604c6975ca75185be07695f47a736004f`. Used no broad main-range diff. Parsed the data-only inventory/manifest hunks without printing every record.
- For the new plugin's lifecycle and receipt-order risk, checked that controller updates run before `renderFrame`, engine beforeRender hooks precede capture, source identity is attached before afterRender, and plugin synchronization uses the existing desired-graph API (`packages/flutter_zyren/lib/src/controller/scene_controller.dart:326`, `:621`; `packages/zyren/lib/src/plugins/engine.dart:806`, `:954`, `:967`, `:1038`). Cleanup removes only the benchmark capture from the current requested plugin list and clears its state (`examples/planet/lib/google_navigation_benchmark.dart:474`). No production pipeline changes were needed.
- Independently verified all 897 inventory entries, 20,851,295 bytes, their size/hash values and all unsanitized decoded source hashes. All three canonical documentation files match their snapshots and recorded hashes. The manifest contains 41 prior commit scopes, including the 903-path earlier evidence commit; no Git provenance re-query was performed.
- Read the existing final results: 15 focused tests passed, exact-file analysis found no issues, and the docs checker passed one page and one Dart sample (`qualification/2026-10-03/rendering-performance/evidence/task-9-validation/fix1/benchmark-final.log:39`, `analysis-final.log:2`, `docs.log:1`). No test suite was rerun because no unanswered code-level doubt required it.
- Confirmed both preserved live summaries still have schema 2, passed false and empty completed-phase lists. No live artifact was rebuilt or newly qualified by this review.
- No source, index, HEAD, branch or persistent configuration mutation. This ignored review report is the only file written. No subagents were dispatched.

# Out-of-Scope Observations

- The prior PPM binary-attribute Minor, dependency/SPM notices, failed foreground route, platform/device-fault limitations and separate whole-change review remain deferred exactly as requested. This scoped approval does not erase them or establish completion of those gates.

# Assessment

- **Task quality: Approved for the scoped fix round.** Both Important findings are addressed with meaningful failure cases, bounded historical source matching and corrected documentation. The amendment remains implementation and focused-test evidence, not foreground performance evidence.
