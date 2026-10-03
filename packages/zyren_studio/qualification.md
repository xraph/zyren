# Studio qualification, 2026-10-03

You can use the editor locally with the pinned Flutter 3.47.5 SDK. Public package
release and full platform qualification are incomplete for the reasons below.

| Area | Implementation | Current evidence |
| --- | --- | --- |
| Documents and history | Schema 2, schema 1 reader, bounded validation and common undo | Round trips, invalid input, external edits and history tests pass |
| Imports | Exact Pipeline pins, explicit source maps and scoped templates | Real GLB load/reimport, rejected invalid map, source selection and history checks pass |
| Prefabs and materials | Nested definitions, instances, overrides and supported materials | Reconstruction tests and native authoring flow pass |
| Animation | Pose recording, key removal/retiming, duration validation and independent previews | Atomic rejection tests, deterministic midpoint sampling and three native preview cycles pass |
| Engineering review | Source/instance binding, note editing and saved review documents | Existing engineering document tests and Studio history pass; notes remain local |
| Collaboration | Durable authority/client, authenticated editor/viewer grants, conflict decisions, conditional inverse, presence, camera following and offline recovery | Multi-client conflicts, denial, lost receipt restart, exact retry and offline conflict tests pass; native local room/edit/close passes |
| Agents | Shared scene, authoring, viewport, diagnostics, timeline, review and disk asset status providers; collaboration on attachment | Schema/grant/retry/stale tests pass; real external MCP flow passes on Metal |
| Presented state | Submitted scene/camera/viewport metadata reaches the presenter receipt | Delayed-render mutation regression and native correlation pass; pixel visibility remains unknown |
| Onboarding | Shared registry with Studio ID and three live anchors | Starts, advances and finishes at desktop/narrow widget sizes and in native runs |
| macOS | Native Metal view | M3 Max native integration and external MCP pass with zero frame readback |
| Android | Native Vulkan shared texture | Physical Pixel 9 Pro, Android 17/API 37 integration passes with zero frame readback |
| iOS | Generated runner and native Metal runtime | Unsigned debug build passes; physical launch blocked by signing |
| Publication | Example, README, changelog and package-local test support | Dry-run blocked by license and five path dependencies; package remains private |

## Verification

The combined Studio/example and rendering regression command passed all 30 tests:

```sh
fvm flutter test --no-pub packages/zyren_studio/test examples/studio/test \
  packages/zyren/test/engine_output_test.dart packages/zyren/test/frame_submission_test.dart
```

Scoped analysis and `tool/check_package_boundaries.dart` pass. The package's Dart
example runs and prints one node and one clip. Earlier in this workstream, all
97 shared timeline/engineering tests passed with the pinned Dart test runner.
Their subprocess tests require the Dart runner rather than Flutter's test VM.

The native test checks picking, a real gizmo drag, overlapping edit denial,
retries, stale revisions, camera preview/restore, idle settling, save/reload,
retired-controller disposal and the narrow layout. It also imports a textured
GLB with an explicit map, reimports a new pin, edits material/clip data, samples
three independent previews, instances a prefab, saves authoring data, opens a
shared session, edits through its registered provider and completes the tour.

The native MCP runner launches the actual external devtools CLI against the
running editor. It verifies the original five runtime providers, source-bound
geometry picking, permitted editing, retry handling, stale rejection, review
permission denial and subsequent native presentation. Additional authoring and
asset-status providers have registry tests; they are not counted as separate
external MCP qualification.

The physical Pixel fixture was also captured and visually inspected at the
396-logical-pixel editor width. Controls and inspector text are readable without
clipping; the orange standard material and textured import are visible. This
capture uses the integration fixture's light theme, not the launcher's dark theme.
[Pixel fixture](../../examples/studio/qualification/pixel-studio.png).

## Resource measurements

After each of three authored previews closed, the main editor's GPU registry
reported four allocations and 3,260 payload bytes, matching its pre-preview
values. Metal reported 98,942,976 device-allocated bytes after every close in the
recorded run. That is the Metal device counter, not physical residency. Android
reported null for device allocation. Both reported null physical residency.

Each preview waited for its own controller to dispose before releasing its asset
scope. The authored document stayed unchanged. These observations establish the
measured lifecycle behavior; they do not qualify unmeasured driver allocations on
Android or long-duration workloads.

## Remaining external and service limitations

- Xcode reports no account and no development provisioning profile for
  `dev.zyren.zyrenStudioExample`. The attached iPhone/iPad are not qualified by the
  unsigned build. Configure signing and rerun the native test on each device.
- Direct desktop visual and accessibility review remains blocked by the locked
  Mac. Automated desktop and narrow layout assertions passed. Windows and Linux
  runners and device qualification are outside this example's current targets.
- Public release needs a project license decision and released, compatible
  versions of `zyren`, `zyren_agents`, `zyren_tools`, `zyren_timeline` and
  `zyren_engineering`. The workspace keeps path dependencies and
  `publish_to: none`. Publisher access has not been verified. Nothing was pushed
  or published. Android release builds still use the generated development
  signing configuration; distribution signing is not configured.
- Remote collaboration agent mutations needing an atomic precommit cancellation
  guard are hidden because the existing network transport lacks that contract.
  Local durable agent mutations and authenticated remote UI operations work.
  Studio does not claim a guard it cannot enforce at the remote commit point.
- Review annotations persist in Studio's engineering document. They are not
  replicated through a transform/visibility session. No second review merge
  protocol has been introduced.
