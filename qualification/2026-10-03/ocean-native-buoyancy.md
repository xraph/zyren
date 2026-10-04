# W9 native buoyancy evidence

Native Rapier tests ran on this macOS host with the pinned SDK. The ocean bridge
passes 10 tests; the native physics package passes 45 tests, including concurrent
perception and state-cache changes present in this checkout.

| Check | Observed acceptance |
| --- | --- |
| Compound collider mass properties | Symmetric compound mass, center and inverse inertia match analytic values before stepping |
| Cargo and density changes | Immediate refreshed mass/COM; prepared water batches reject changed state |
| Rotated inverse inertia | Predicted angular impulse response agrees with native velocity within 1e-6 |
| Atomic loads | Invalid later commands leave earlier actors unchanged |
| Transient gravity balance | Position and velocity stay within 1e-8 in the native force fixture |
| Contribution ownership | Consumed once; independent cancellation and per-actor removal preserve other force sources |
| Cube settling | At 30, 60 and 120 Hz, final height is within 0.02 m and speed below 0.04 m/s after eight seconds |
| Cube convergence | 30-to-120 Hz final position difference below 0.01 m; 60-to-120 Hz below 0.005 m |
| Four-pontoon vessel | Settles, rights initial heel, then heels and lowers after asymmetric cargo |
| Overload | A separately bound dense cube sinks below five metres |
| Sleep and currents | Balanced sleep persists; dry or moving-water cases wake and accelerate the body |
| Cadence and visibility | Every 60 Hz trajectory point matches within 1e-7 m across 30/60/120/144 Hz presentation, including hidden frames |
| Frame transfer | ECEF position within 2e-5 m, velocity within 1e-6 m/s; external loads survive rebasing |
| Async lifetime | Close, detach, source change, timeline reset and cargo change invalidate pending work without applying partial loads |
| Replay and availability | Unavailable water rejects forces; restored worlds require new handles and a newer clock generation |

The initial impulse implementation showed tick-dependent settling bias. At eight
seconds, a cube's vertical speeds at 30, 60 and 120 Hz were about -0.121, -0.057 and
-0.025 m/s. Rapier integrates gravity across internal intervals, while an impulse
acts before those intervals. The bridge now queues a force across the same native
step. The stronger static position-balance fixture and trajectory tests pass.

Commands from the respective package directories:

```sh
/Users/rexraphael/fvm/versions/3.47.5/bin/dart test --concurrency=1 --reporter expanded
```

Native state-count tests require serial execution because their native registry
is process-wide. An early parallel run failed a registry-count assertion; the
serial run passed without changing that assertion.

Presentation tests execute the real SceneEngine/PhysicsPlugin callbacks with a
pixel stub, not native GPU water draws. Visual presets are outside the bridge's
API; the actual W11 controller independence test remains pending. No mobile,
Windows, GPU-performance or visual-acceptance result is inferred from this record.
