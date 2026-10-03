# Foundation checks

Sequential implementation on the active `main` checkout, 2026-10-03.
Use Flutter 3.47.5 and its bundled Dart SDK. This checkout has no `.fvm` directory;
the installed SDK is `/Users/rexraphael/fvm/versions/3.47.5`.

## Verified behaviour

- Extension composition validates before backend allocation, keeps independent
  scopes and reports surviving registrations after failed updates.
- Layer transactions reject cycles and stale revisions atomically. Restored
  definitions retain saved visibility and order, then acquire real capabilities
  and readiness from their attaching adapter. Live restores republish readiness.
- Terrain instances isolate source failures. Imagery replacement keeps prior
  coverage through failure, and native pixels respond to opacity and ordering.
- Clock and simulation leases reject competing drivers. Their ownership survives
  asynchronous shutdown until pending work drains. Game-session ticks drive native
  physics once; rendering and geospatial observation do not advance it again.
- Camera rigs own separate base poses and share one input owner. Modifiers run by
  priority then ID, declare affected components and pass through the active rig's
  constraints before publication. Existing PointOfView callers use the same pose
  type, with optional perspective projection state.
- Visual contributions register real compute, render or colour-chain effects in
  the existing native graph. The native two-effect fixture verifies dependency
  order at 96x64 and 40x96 and checks resource retirement after disposal.

## Commands

From the geospatial package, the full suite passed with 286 tests and 21 skips
before the final camera-component and live-restore regressions were added. Focused
follow-up checks passed for those additions. The execution ledger records the
final full-suite result after the F5 commit.

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/dart test --concurrency=2
```

The 25 core composition, plugin-update, engine and GPU-service checks passed.
The Planet game-clock fixture passed with native physics. Run the native layer
application check from `examples/planet`:

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/flutter test integration_test/layers_test.dart -d macos --no-pub
```

The application test verifies camera switching, east-source failure and retry,
continued west-source readiness, saved visibility after creating a new view and
layout at 1000x700 and 390x700. A normal app run was also inspected through native
screenshots at 800x632 and 391x632 logical window sizes. The screenshots in this
chat show the procedural terrain, selected camera and wrapping controls. They are
functional fixture evidence, not water-quality references.

## Limits

The local native checks use Metal. Android, iOS, Vulkan and DX12 device results
remain unverified for these additions. Twenty-one atmosphere/cloud cases need
pinned source assets and remain skipped without them. Managed globe rigs require
perspective cameras. Legacy standalone controls remain available.

The repository-wide dependency check still reports the concurrent Studio
`crypto` import in `packages/zyren_studio/lib/streaming.dart`. Analysis of owned
files is clean. An unrelated in-progress `horizon.dart` file has a style diagnostic
in the package-wide scan. Neither file belongs to this change.

The lab saves layout JSON in application support storage. That is not the offline
resource cache planned in D1-D4. Water, real provider coverage, traffic, flight and
orbital solvers are not qualified by these foundation checks.
