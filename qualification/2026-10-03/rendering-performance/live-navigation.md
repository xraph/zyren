# Planet native route attempt

The five-phase real-provider route is unqualified. Neither attempt completed a
phase. Preserve the partial records for diagnosis, not a before/after FPS claim.

The macOS profile bundle used source HEAD `403910cdad63884bb57ab85829e583d19f5c643c`,
with exact source file hashes and bundle identities in
[evidence/task-9-validation/planet-profile-artifact-before.json](evidence/task-9-validation/planet-profile-artifact-before.json).
The loaded native framework hash was
`3154b8ff18f18df791bf4029fbe9f9a8d23306f156f57659f944ff6ac8731ff1`.
The host executable hash was
`c22dc05d33b2e68c4b6d165aa8c7e1d3d1b75a234ce3302d33e64637d3da8c7a`.
Both remained unchanged after the attempts. The Dart AOT image was observed later,
during restoration, as
`aa557e6396a0be2114d1e2418df3c61f5c540c9b05616fe997483252adafd325`,
with the earlier profile-build modification time. That is a late observation,
not a contemporaneous loaded-image hash.

The exact Profile/planet.app path was selected through native CUA. Its window
showed Tokyo buildings, river, clouds and Google/Cesium attribution. The build
runner itself reported failure to foreground the app. CUA's window Raise and
canvas click were attempted, and the first run initially reported `resumed`.
It changed to `inactive` during stationary measurement. The second run reported
`inactive` immediately. CUA's optional app-launch method was unavailable.
No foreground gate was relaxed. No other app or connected device was stopped.

Settings were Auto, fixed weather, nativeView Metal on Apple M3 Max, 1600 by 1128
render pixels, 60 FPS application cap, high requested cloud preset, enabled
shadows, density 1 and sparsity 0. Requested and applied cloud adaptation were
both true, and controller diagnostics also reported enabled. Effective stride
was 4 and shadow cadence 1 with no quality transition. The diagnostic reason
retained `timingUnavailable` from a prior sample even while the current scene GPU
value was present; it is not evidence of a disabled policy.

The first partial contained 34 accepted presentations across 2.968 seconds:

| Partial stationary measurement | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Presentation interval, ms | 85.245 | 138.774 | 146.231 |
| Scene GPU interval, ms | 9.959 | 17.820 | 34.638 |
| Native preparation, ms | 0.760 | 1.353 | 1.462 |
| Native encoding, ms | 1.352 | 2.051 | 2.170 |
| Native completion wait, ms | 10.348 | 18.190 | 39.267 |

These are interrupted samples, not a completed stationary result. Named pass GPU
times remain null on this Metal profile. CPU waits overlap GPU work and must not
be added to it. Diagnostic sampling frequency was not used as display FPS.

All sampled frames had zero pixel readback and upload backlog, 421 visible and
displayed tiles, 1,024 selected tiles, zero prefetched tiles/bytes and no tile
failure. Tile payload was 400,972,042 bytes and selection was budget limited.
Cloud history advanced through the measured sample range. Those counts and the
visible city image do not prove complete geometric coverage. NativeView did not
supply `FrameStats.residentBytes`; registry payload and physical GPU residency
therefore remain null. Cumulative native uploads and resource submissions remain
available in the raw profiles.

Both attempts released benchmark input registrations. That cleanup leaves the
interactive scene alive and cannot prove complete app/GPU teardown. Native fixture
cleanup is separate evidence. Orbit, drag, zoom and the explicit reversal were not
reached, so their live performance, prefetch behavior, image stability and motion
coverage remain unverified.

No own GPU-heavy test or build overlapped the measured interval. Other Studio and
game apps were running on this shared host, and their GPU activity was not measured
or controlled. The failed partial and immediate retry each have separate raw frame,
summary and collector records. The ordinary interactive target is restored after
the route; restoration observations are recorded in `restoration.json`.
