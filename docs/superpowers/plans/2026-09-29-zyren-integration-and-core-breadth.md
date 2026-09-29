# Zyren integration, native qualification and core breadth

The user asked to execute items 1 through 4 from the remaining-work report:
integrate the core with Zyren, qualify native platforms, finish performance
qualification and close the listed core gaps. Geospatial parity remains a
separate workstream, but its existing plugins must keep working after integration.

Work in the existing dart-core-api checkout. Main has concurrent terrain edits.
Integrate committed main changes here, preserve both branches' behavior, and
commit checked increments locally. Keep native Metal/Vulkan/DX12 execution.
Unavailable physical devices remain explicit qualification gaps.

## Task 1: Integrate the core and Zyren

Normalize package, native-library and host-plugin names to the accepted Zyren
family. Combine the core renderer with the committed main branch, retaining
planetary depth, navigation, diagnostics, feature styling, fragment coverage,
terrain/tiles and the workbench plugins. Reconcile public APIs and packet
opcodes at their consumers, not just through textual conflict resolution.

Run workspace analysis, package boundaries, header synchronization, all Dart and
Flutter package tests, Rust tests and native Metal fixtures. Add regressions for
integration defects before repairing them. Run the physical-material gallery and
an existing geospatial/native workbench scene. Expected: both use one Zyren core,
no obsolete duplicate packages, passing suites and unchanged native ownership.

## Task 2: Qualify available native devices

Discover physical iOS, Android and Windows execution targets. Run combined
material, compressed texture, shadow and temporal fixtures on each available
target, with presentation readback, resize and teardown assertions. Record exact
device/OS/backend, failures and recovery behavior. Fix reproducible faults with
regressions. A cross-compile is not a runtime pass. Expected: evidence for every
available target and an explicit unavailable status for the rest.

## Task 3: Performance, memory and recovery

Remove unnecessary shadow redraws during camera translation without sacrificing
planetary precision or caster/light invalidation. Profile physical area lighting
and reduce repeated work while preserving reference pixels. Add optional native
GPU timestamps with capability admission and unavailable values left unknown.
Measure presentation pacing separately from readback latency. Exercise sustained
allocation bounds, view replacement, suspend/resume and failure recovery.
Expected: reproducible before/after profiles, bounded residency and no hidden
precision or visual regression.

## Task 4: Remaining core breadth

Add text-outline geometry, subdivision and CSG with bounded input and useful
Dart APIs. Extend optional asset interchange with additional loaders/exporters
and round-trip tests. Audit camera/control and animation contracts against the
existing plugins; fill concrete gaps without duplicate controllers or mixers.
Extend temporal motion to custom shader and line/point paths. Improve area-light
visibility quality and support nested refractive surfaces with explicit memory
and layer limits. Each feature needs independent expected results, failure tests,
a native consumer where relevant and documentation of its supported range.

## Interfaces and review focus

Package names cross FFI hooks, platform registrants, symbols and build scripts.
Native scene/resource opcodes must agree with every Dart producer. Main adds
planetary depth and coverage that shadows, temporal passes and material variants
must retain. Diagnostics and plugin snapshots must continue to report actual
resource ownership. Timestamp queries and refractive/shadow intermediates must
obey device features and view disposal. Geometry operations need bounds for
degenerate, non-finite and adversarial input. One final independent review checks
these boundaries after implementation; important findings get failing regressions.
