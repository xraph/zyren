# Cached promotion progress

Status: DONE_WITH_CONCERNS. N1 is fixed and the scoped Dart checks pass. The controller's single N1 review remains pending; earlier live qualification limits are unchanged.

Cached speculative content now makes room in the visible budget before promotion. `_makeRoom` contains the existing ordinary-admission eviction loop and serves both paths, preserving its order and eligibility rules. Promotion checks actual decoded and logical resident content bytes against both visible quotas. It can reclaim only unselected, unpinned entries in that lane. Displayed, staged and submitted cover remains pinned, physical request reservations stay charged, and transferring cached content does not refetch it or add a new reservation.

Three regressions follow A -> D -> prefetched B with a fixed clock, fresh non-provider content and tracked receipts. They separately constrain decoded bytes, resident bytes, and both. Before selecting B, all loads have drained, A remains cached but unselected/unpinned, D is displayed, and B is already fetched. Four subsequent receipt/update cycles must display B, reclaim A, preserve the D/B overlap and keep the resolver reads exactly `/a`, `/d`, `/b`. Counters remain bounded. The existing pinned-cover denial test is byte-identical to its pre-fix version and still passes.

All three new cases failed against the original implementation because visible D remained selected for publication instead of B. `promotion-liveness-validation/red.log` preserves the failures. The correction passes the entire motion file and tiles suite.

Commands ran in `packages/zyren_3d_tiles` with FVM:

- `fvm dart test test/motion_test.dart --name 'cached promotion reclaims'`: 3 failures before the fix, all at the expected B-versus-D progress assertion. Raw `red.log`.
- `fvm dart test test/motion_test.dart`: 11 passed, including the unchanged pinned-cover control and cancelled-I/O reservation checks. Raw `focused.log`.
- `fvm dart test --concurrency=1`: 97 passed. Raw `tiles-full.log`.
- `fvm dart analyze lib/src/streamer.dart test/motion_test.dart`: no issues. Raw `analyze.log`.
- `git diff --check` on the two owned paths: clean. The shared index was empty before the isolated commit.

Commit: `9a98bf8ad09a669dbfaa94b986ccbdf5ff51c72a`, `fix(tiles): reclaim inactive cache for visible promotion`.

Exact owned paths:

- `packages/zyren_3d_tiles/lib/src/streamer.dart`
- `packages/zyren_3d_tiles/test/motion_test.dart`

The commit used a temporary isolated index, exact paths and a HEAD compare-and-swap on shared main. `promotion-liveness-commits.jsonl` records its parent and scope. `promotion-liveness-validation/source-identity.json` records source hashes and the unchanged pinned-control hash. Concurrent work remains intact. No helper, native suite, app rebuild, metadata closeout, push, merge, branch change or scratch deletion occurred.

The partition still intentionally reduces maximum visible cache capacity, and promotion still waits when pinned content or live reservations prevent it from fitting. These remain logical budget limits, not measured GPU residency. This narrow repair does not qualify foreground motion, physical gestures, provider-route completeness, Auto transitions, other platforms, thermal behavior or physical fault recovery. Ruling 59 authorizes this scoped correction; all original nine finding dispositions remain outside this repair.
