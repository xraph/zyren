## Finding verdict

**N1, cached prefetch promotion stalls behind evictable visible cache: ADDRESSED.** `packages/zyren_3d_tiles/lib/src/streamer.dart:209` now checks both decoded and logical resident headroom through `_makeRoom(false, hasRoom)` before transferring a selected cached tile into the visible lane. The shared helper at `:720` reclaims only entries in the eligible lane that are unselected and not held by displayed/submitted/staged cover or a fade. The ordinary request path calls the same helper at `:774`, preserving its former eviction order and eligibility rules.

This removes the specific no-progress state: fresh, unselected, unpinned A can be reclaimed so displayed D and already-prefetched B fit together. B remains cached, gains no physical request reservation and is not fetched again. Its lane changes only after both quota checks pass. Live request reservations remain included in `_laneBytes`; no cancellation accounting is released early. If pinned content or active reservations still prevent admission, promotion continues to wait as intended.

## New breakage in the fix diff

**Critical: none. Important: none. Minor: none established.** The helper extraction preserves the previous ordinary-admission loop. Iteration over a copy of speculative IDs tolerates cache removal, and missing entries are checked before use. Selected and held content remain ineligible for eviction. The fix is confined to the two owned Dart files and does not change partition sizes, publication receipts or native resource handling.

## Regression and evidence checks

- Reviewed the brief, implementation report and exact 9,453-byte diff for owned commit `9a98bf8ad09a669dbfaa94b986ccbdf5ff51c72a`. The broader shared-history package was not used as the attribution boundary. The original nine findings were not reopened.
- The three cases beginning at `packages/zyren_3d_tiles/test/motion_test.dart:337` reproduce A -> D -> prefetched B using tracked receipts, a fixed clock and fresh non-provider data. They independently constrain decoded bytes, resident bytes and both. Before selecting B, they assert A remains cached but unselected, D is displayed, B is prefetched, all reservations have drained and the only resolver reads are `/a`, `/d`, `/b`.
- The tests then repeat receipt/update cycles and require B to become visible and displayed, A to be reclaimed, cached bytes to retain the D/B overlap, no new resolver reads and bounded counters. This exercises promotion without unrelated requests or freshness expiry, which was the missing progress trigger.
- Read `promotion-liveness-validation/red.log`: all three pre-fix cases fail the expected B-versus-D visibility assertion. Read `focused.log`, `tiles-full.log` and `analyze.log`: 11 motion tests pass, 97 tiles tests pass and targeted analysis reports no issues. No suites were rerun during this review.
- Both current source hashes match `promotion-liveness-validation/source-identity.json`. Independently compared the existing pinned-cover denial test against the commit parent: byte-identical, SHA-256 `ec4563432f360bcf79ad67af1c7941deb90d4a8009c952f588bf1294ce7d9f75`. Its passing result remains a useful control showing that reclaimable-cache progress did not become permission to evict pinned cover.

## Limits and out-of-scope observations

- No unrelated observations added. Scope is N1 and breakage introduced by this narrow correction, under Ruling 59.
- Enabled prefetch still reduces maximum visible cache capacity. Pinned cover or physically active reservations may still prevent promotion. These are the accepted partition costs, distinct from the corrected evictable-cache stall.
- Tests verify logical admission and publication behavior. They do not measure physical GPU residency or establish foreground smoothness, gestures, provider-route completeness, live Auto transitions, platform/thermal behavior or physical fault recovery. Earlier qualification limits remain unchanged.
- No app refresh, native validation, source/index/HEAD/branch mutation or helper use occurred in this review. Only this ignored report was written. Ordinary app refresh and durable closeout remain controller work after this gate.

## Verdict

**N1 gate: PASS. Finding addressed, no new Critical or Important breakage.** The scoped code-quality and specification requirement for cached-promotion progress are satisfied. This closes the remaining reviewed source defect without changing the independently incomplete live qualification.
