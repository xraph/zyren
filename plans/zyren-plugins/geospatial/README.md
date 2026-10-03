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
| 1 | [Extension host, layers and world services](01-foundation-plan.md) | F1-F5 | F1-F5 implemented; native Metal checks recorded |
| 2 | [Persistent caching and offline regions](02-offline-plan.md) | D1-D4 | D1-D3 implemented; field adapters and lab next |
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

F4 checks: 16 world-frame and clock tests, 10 extension tests and 4 legacy tests
passed. The Planet application fixture passed with native physics: 60 game ticks
produced 60 physics steps, and camera-only frames changed neither. Analysis passed.
Clock and system ownership remain reserved until pending asynchronous work drains.
Time standards are labelled; leap-second conversion and ephemeris data are not
provided. The concurrent Studio boundary issue recorded above remains.

F5 adds managed camera rigs, ordered pose modifiers, versioned styles and actual
native graph registrations. The Planet layer lab covers source failure/retry and
persisted layout with a native application test at wide and narrow sizes. See
[foundation evidence](foundation-evidence.md) for commands, screen observations,
interface adjustments and unresolved platform checks.

D1 checks cover 19 resource identity, access, transport and request-pool tests.
Resources use immutable bytes, SHA-256 identity and explicit source permissions.
Offline reads never construct transport locations. Native source reads preserve
byte limits and redirect policy. Analysis passed. Repository boundary checking
remains blocked by concurrent Studio and training-worker crypto imports. The
reference store is memory-only; durable storage and verified regions follow.

D2 adds a native file store with a checksummed index journal, bounded staging,
manifest-owned pins and process/isolate exclusion. Twelve storage tests passed
on macOS, including abrupt child-process exits at all four publication stages.
The complete D1/D2 suite has 31 passing tests. Analysis passed. Linux, Windows and
power-loss durability remain unqualified. A corrupt committed index fails closed
instead of reconstructing unknown pin ownership from payload filenames.

D3 checks include a fresh child process with transport forbidden, quantized-mesh
loading, native PNG decoding, scheduler parent fallback, camera movement outside
stored detail and recovery with a fresh online source. Region checks cover
missing dependencies, cancellation/restart, revoked export permission, failed
replacement publication, stale-writer rejection, dateline coverage and Mercator
limits. The affected data/terrain/streaming suite passed 106 tests after the final cancellation-permission fix. Owned-file analysis
passed. Concurrent cloud tests have three unrelated style diagnostics.

D4 adds bounded coast/depth fields, scoped data diagnostics and a native offline
lab backed by the file store. Its download, cancellation, denial/retry and cold
reopen flow passed at desktop and narrow sizes. All 111 affected data, terrain and
streaming tests passed. The model adapter keeps verified pipeline bundles under
their existing ownership at the application boundary. See the
[offline qualification record](../../../qualification/2026-10-03/geospatial-offline.md).
Manual native-window inspection remains pending because the Mac was locked.

W1 adds versioned Phillips sea states, deterministic canonical coefficients and
an independent bounded inverse DFT. Eleven numerical tests passed, including
finite-depth limits and displacement/velocity derivatives checked by finite
differences. A separate Python calculation reproduced the fixture coefficient
hash. Package analysis and boundaries passed. Native FFT and rendering are next;
these numerical checks do not qualify ocean visuals.

W2 adds native Stockham FFTs, packed displacement/derivative/velocity textures
and atomic field publication. Nineteen wave tests passed with native GPU execution,
including 4/8 complex oracle comparisons, 64..512 grid coverage, actual allocation
failure, cancellation and zero remaining owned allocations. Analysis and package
boundaries passed. [Compute evidence](../../../qualification/2026-10-03/ocean-compute.md)
records payload sizes and the limits of the cold timing sample. Globe geometry,
physical queries and water optics remain separate tasks.
