# History, accessibility and Apple qualification, 2026-10-03

You can undo and redo scientific field and slice edits through the public API,
Flutter controls or shared agent tools. History retains immutable source values
and settings within count and payload limits. It rebuilds geometry and native
resources when you restore an entry. It is session-local, with no disk persistence.

## Verification

| Check | Result |
| --- | --- |
| Package suite | 40 tests passed, including native Metal fixtures |
| Focused history suite | Five tests passed |
| Static analysis | No diagnostics |
| Flutter accessibility widgets | Six tests passed |
| Field and slice stdio MCP | Passed, including byte-identical native images after undo/redo |
| macOS, Apple M3 Max, Metal | All four integration tests passed; native presentation with zero readback bytes |
| iPhone 16 Pro, Apple A18 Pro, iOS 27.0 (24A437), Metal | All four integration tests passed; all six modes used `nativeView` with zero readback bytes |
| iPad Pro 13-inch (M4), iPadOS 27.0 (24A437), Metal | All four integration tests passed; all six modes used `nativeView` with zero readback bytes |
| Human VoiceOver listening walkthrough | Unverified |
| Windows DX12 and Linux Vulkan | Unqualified; no local host and no registered shared Flutter presenter |

The earlier [Pixel recheck](2026-10-03.md) passed Vulkan presentation and agent
picking before this history/accessibility follow-up. It does not establish that
the new controls have had a physical Android screen-reader walkthrough.

The history checks cover temporal source restoration without reloading changed
external data, stale revisions, cancellation, failed preparation, redo invalidation,
count/byte eviction, grants, retries and slice restoration. Failed operations leave
the current view and history unchanged. The field and slice MCP checks also verify
read-only denial, stale-command rejection and clean EOF teardown.

## Accessibility and recovery

The widget checks cover all six representation choices at 390 logical pixels with
100% and 200% text, 320 pixels with 300% text, and 1100 pixels with 100% text.
They check Android/iOS target sizes, accessible names, contrast, selected/enabled
states, slider units, semantic actions and keyboard activation. Source sampling
retains labelled X/Y/Z coordinates and a changing scalar/vector readout at 300%
text. Camera rotation, zoom and reset have seven named button actions.

Direct macOS accessibility-tree inspection and interaction found two defects:
tooltip-only icon names were missing, and opening a modal panel triggered Flutter
AXTree update errors. Explicit icon semantics and inline source/camera panels
resolved both in the inspected lab. No AXTree error appeared in the final native
inspection log. These checks establish the tested semantics and interactions;
they do not establish spoken announcement quality or general WCAG conformance.

The device integration check exercises source sampling through semantic actions,
volume undo/redo, Ctrl/Cmd+Z shortcuts, camera buttons, temporal seeking and native
agent picking. It also checks that a failed edit rolls back the slider preview,
keeps history intact and exposes Retry. Empty geometry exposes Show slice and
recovers. An explicit workbench focus scope restores keyboard shortcuts after
async edits and panel closure.

## Native results

The iPhone and iPad volume fixtures returned the same center RGBA values:

| Fixture | RGBA |
| --- | --- |
| Constant red, opacity 0.5 over 1 m | 127, 0, 0, 128 |
| Same volume, step 0.07 m | 127, 0, 0, 128 |
| Red/blue scalar ramp at midpoint | 94, 0, 94, 128 |
| Clipped to half the depth | 75, 0, 0, 75 |

Opaque depth, reversed depth, missing voxels and work limits passed. Owned native
resources, shader programs and materials reached zero after teardown. Timeline
demand and volume-plugin detachment also passed. Physical GPU residency remains
unknown. Numerical fixtures use offscreen readback; the separate Flutter
presentation checks require zero readback bytes.

The iPhone agent pick joined triangle 855 to source cell 5031 on a 402 by 470
logical-pixel canvas at DPR 3. The macOS join returned the same triangle and cell
on an 800 by 388 canvas at DPR 2. The iPad join matched on a 1376 by 768 canvas at
DPR 2. The native fixtures and Flutter test now register
with one test runner, so device startup and teardown run sequentially. Frame waits
use the viewport's latest frame statistics rather than the throttled UI readout.

An early iPad run passed the numerical Metal fixtures and the first five modes,
then rejected volume rendering at its full-resolution work estimate. The example
now samples at its synthetic grid spacing, 0.1 m. The coordinated retry then found
that a 2752 by 1632 canvas exceeded the renderer's 128 MiB HDR target budget.
The lab caps its rendered canvas at two million pixels through the existing
`SceneView.resolutionScale` API, preserving logical UI and picking coordinates.
The pixel-sample and HDR memory ceilings are unchanged. Interrupted wireless debug
attachment attempts are not counted as passes.

The corrected build passed all four tests on macOS, iPhone and iPad. The iPad's
volume frame rendered at 1836 by 1089 pixels with zero readback bytes. The cap
allows integer dimension rounding; all six modes stayed below 2,004,000 rendered
pixels. The iPhone retained its 1206 by 1482 volume frame without scaling.

## Reproduction and evidence

Use Flutter 3.47.5 and Xcode 27.0 (27A266a). From the package directory:

```sh
RUN_NATIVE_GPU=1 dart test --reporter expanded
flutter analyze --no-pub
python3 example/verify_field_mcp.py /path/to/flutter/bin/dart /tmp/scientific-field-mcp
python3 example/verify_mcp.py /path/to/flutter/bin/dart /tmp/scientific-slice-mcp
```

From `example/flutter`:

```sh
flutter test --no-pub test/accessibility_test.dart
flutter test --no-pub -d macos integration_test/scientific_test.dart
flutter build ios --debug --no-codesign --no-pub -t integration_test/scientific_test.dart
# Sign the built app using a valid development profile for the target device.
flutter drive --no-pub --debug --keep-app-running \
  --driver=test_driver/scientific_test.dart \
  --target=integration_test/scientific_test.dart \
  --use-application-binary=/path/to/signed/ScientificLab.app -d <device-id>
```

The wireless iPad run required `--ipv6 --no-dds`; the final iPhone run used
`--no-dds`. Both completed through the Flutter driver. Startup and teardown
markers are retained so a connection attempt cannot be mistaken for a pass.

Private evidence on the qualification host:

| Evidence | Path |
| --- | --- |
| Package and focused history tests | `/tmp/scientific-integration-core.log`, `/tmp/scientific-history-tests.log` |
| Analysis and accessibility widgets | `/tmp/scientific-resolution-analysis.log`, `/tmp/scientific-accessibility-widget.log` |
| Final native-volume registration check | `/tmp/scientific-native-volume-final.log` |
| Field MCP verification and native images | `/tmp/scientific-history-field-mcp/` |
| Slice MCP verification and native images | `/tmp/scientific-history-slice-mcp-final/` |
| Direct native accessibility inspection | `/tmp/scientific-inline-live-macos.log` and this chat's accessibility-tree observations |
| macOS integration | `/tmp/scientific-macos-resolution-final.log` |
| iPhone integration | `/tmp/scientific-iphone-resolution-final.log` |
| iPad integration | `/tmp/scientific-ipad-resolution-final.log` |
| Apple build and signature check | `/tmp/scientific-ios-resolution-build.log`, `/tmp/scientific-ios-resolution-sign.log` |
| Source and signed binary SHA-256 hashes | `/tmp/scientific-integration-artifact-context.json` |
| Temporary app removal | `/tmp/scientific-ipad-cleanup.log`, `/tmp/scientific-iphone-cleanup.log` |

The signed test artifact uses the temporary bundle alias
`dev.xraph.zyren.physicsLab` and an existing valid development profile. The
checked-in scientific bundle identifier is unchanged. With the user's permission,
Physics Lab and the inactive App Flutter development build were removed from the
iPad to free development-app slots. Planet and XR apps were retained. After the
final passes, the temporary Scientific app was uninstalled from both Apple
devices and the coordinating chats received release notices.

Implementation commits are `07d6b34`, `eecb93ac`, `587d4938` and `7d3f953c`, local on `main`.
The checkout includes concurrent renderer work, so these results qualify the
recorded artifacts and runs. Nothing was pushed or published.
