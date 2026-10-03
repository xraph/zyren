# Geospatial extensions and professional water

The architecture and ocean-first delivery order were approved on 2026-10-03.
Professional water effects, buoyancy, LOD and effective quality controls are
required. Sequential implementation started on 2026-10-03.

Read the [platform design](design.md), [ocean specification](ocean-design.md) and
[reference audit](water-reference-audit.md) before executing the plans. The audit
distinguishes TwinOS's current analytic water and transform following from the
native spectral simulation and physical buoyancy required here.

| Order | Plan | Tasks | Current status |
| --- | --- | --- | --- |
| 1 | [Extension host, layers and world services](01-foundation-plan.md) | F1-F5 | F1-F3 implemented and checked; F4 next |
| 2 | [Persistent caching and offline regions](02-offline-plan.md) | D1-D4 | Queued for sequential execution |
| 3 | [Native professional ocean](03-ocean-plan.md) | W1-W12 | Queued for sequential execution |

Navigation/traffic, flight and orbital simulation remain in the approved platform
scope. Their provider/solver specifications follow the foundation and ocean work;
these three plans do not claim to implement them.

## Water delivery requirements

- Native spectral waves and shared physical samples with known time/error.
- Continuous globe coverage, camera-independent phase and crack-free mesh LOD.
- Reflections, refraction, absorption/scattering and underwater optics.
- Persistent foam, wakes, ripples and bounded spray.
- Native buoyancy from pontoons and closed convex hull proxies.
- Low/Medium/High/Ultra render profiles with measured resource/work limits.
- A native lab with offline data, regression fixtures and device evidence.

Visual quality, mesh detail and physical-query quality are separate. Quality
changes cannot alter the canonical sea state or physical tick rate. Initial
performance targets and profile budgets are assumptions for qualification,
not observed results.

## Execution and evidence

You approved the architecture and selected sequential execution in this chat.
Work stays on the active branch. Each task records its checks and a focused
local commit before the next task starts.

Use one task at a time, its focused checks, then a local commit. Maintain the
completion matrix in plan 03 with actual numerical, native and device results.
Keep concurrent changes and existing APIs intact. No plan authorizes publishing,
pushing, merging or replacing another chat's work.

This planning delivery checks document links, file references, interfaces and
scope. It does not run runtime tests or qualify native water. Earth coast data,
provider access, target-device results and final visual acceptance remain explicit
requirements, with their status recorded during implementation.

F1 checks: 25 core composition/lifecycle/GPU-service tests and 13 geospatial
composition/legacy tests passed. Analysis and package boundaries passed. These
checks use the engine test renderer and do not qualify native water visuals.

F2 checks cover 15 layer transaction, selection and codec tests, including
configuration restore ownership, plus 10 extension lifecycle tests and 4 legacy
plugin tests. Analysis passed. The current repository boundary check reports an
unrelated concurrent `zyren_studio/lib/streaming.dart` import of `crypto`. Layer
state is headless; renderer adapters are the next task.

F3 checks: 100 targeted layer, streaming, terrain, imagery, overlay, extension and
legacy atmosphere tests passed. Native fixtures verified imagery opacity and
ordering at 192x128 and 96x160, hidden cache retention, atmosphere visibility and
owned resource cleanup. No water rendering or mobile/Windows qualification is
claimed by these results. Analysis passed.
