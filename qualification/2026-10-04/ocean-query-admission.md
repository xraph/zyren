# Saved ocean query admission, 4 October 2026

Scene revision `ocean-lab-scenes-2` reduces horizontal choppiness from 0.7 to 0.12
for storm and from 0.5 to 0.2 for orbit. Wind, amplitude, seed, canonical grid and
vertical wave spectra are unchanged. A regression compares the evolved height
coefficients with the previous sea states at 0, 1, 10 and 30 seconds.

The sampler was correctly rejecting revision 1. Its conservative horizontal
contraction must be below 0.8 to establish an invertible surface. The old storm
fixture measured 3.64 to 3.69 at those timestamps, and orbit measured 1.49. The
revised fixtures measure 0.624 to 0.633 and 0.596 to 0.597 respectively. The query
policy and the inverse solver have not changed.

Seven regression tests pass, including 72 samples across six scenes, three local
positions and four timestamps. They retain the default limits: 1 cm height,
0.5 degrees normal and 0.1 m/s velocity error, with zero result age. This is
bounded numerical model accuracy at the recorded points, not a proof of every
position/time or agreement with ocean measurements.

The two offline/source tests and the six-scene native render/lifecycle test also
pass. A separate two-frame 640x400 Metal run records all 18 final physical samples
as available and zero owned allocations/graphs after every scene closes. See the
[report](ocean-scenes-2/report.json) and
[envelopes](ocean-scenes-2/query-envelopes.jsonl). Four revised storm/orbit stills
are retained beside the report. With fewer than five warmup frames, this run makes
no timing claim.

The revised six-scene integration also passes on a physical Pixel 9 Pro running
Android 17. Every scene reports zero presentation readback at 960x1989. The [device receipt](ocean-scenes-2/pixel-native.json) records at least six
simulation ticks in every scene, including the buoyant vessel. Pause, independent
layers, responsive panels and awaited page/controller disposal also pass. Global
Android allocation counters and sustained frame rate were not measured.

The earlier 60-frame report and motion video remain revision-1 evidence. They are
not silently replaced. Horizon artifacts, professional visual review, sustained
performance and physical device qualification remain open.
