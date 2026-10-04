# Ocean physical query evidence

W4 connects canonical spectral fields to batched body-fixed surface queries.
Implementation runs on the CPU worker or native compute. Physical buoyancy and
water shading are separate tasks and have not passed from these results.

## Checked behaviour

- Known displaced surfaces recover their material points at chart seams and poles.
  The inverse uses full analytic derivatives, bounded travel, damped Newton steps
  and explicit folded, singular, nonconvergent and accuracy failures.
- All canonical modes contribute. Actual visual FFT allocation changes from an
  8 x 8 grid to 4 x 4 leave CPU and GPU physical heights bit-identical within each
  backend, with the same sea-state revision.
- Coverage has an explicit provider. Partial land batches preserve input order;
  unavailable sources return no physical value. Access is checked after physical
  work, and source/frame/timeline revisions fence delivery.
- A deterministic delayed-readback device checks reset, rebase, source revision,
  source removal, elapsed simulation time, cancellation and close. This device
  tests lifecycle only; its zero output is used only with zero wind. Native numeric
  checks use the real backend.
- Close retains resources until delayed readback drains. The worker deadline test
  kills a stalled isolate and waits for exit before releasing admission. Native
  partial-allocation rollback preserves reusable buffers. Cleanup returns owned
  native allocations to zero.
- Work and memory admission include canonical preparation, every Newton evaluation,
  worker cache/replacement payload, host packet transfers and GPU candidates.
  Busy calls, excessive distinct ticks and mode budgets fail explicitly. Large
  tick differences are compared with BigInt and cannot wrap into a fresh result.

## Native comparison on this Mac

A 24-point deterministic world sweep uses WGS84, seed 42, one 64 m band, canonical
resolution 8, wind speed 12 m/s, amplitude 0.0002, choppiness 1 and simulation time
1.3 seconds. Portable strict policy is 1 cm height, 0.5 degree normal and 0.1 m/s
velocity. Every sample passed its reported numerical estimate.

| Measurement | Observed result |
| --- | --- |
| Maximum CPU/GPU height difference | 6.535429297738204e-8 m |
| Maximum normal angle difference | 1.160638334342681e-8 rad |
| Maximum fluid velocity difference | 1.0545483357587863e-7 m/s |
| Native chart dispatches for the batch | 18 |
| Visual 8 x 8 field payload | 13,424 bytes |
| Visual 4 x 4 field payload | 3,408 bytes |

The numerical field tests also cover canonical grids 8, 32 and 64, multiple bands,
zero wind with nonzero mean level, Earth-scale chart coordinates and long times.
Small-grid fields agree with the independent Float64 reference. Those field tests
do not extend the world-query fixture's measured precision to every sea state.

## Accuracy assumptions and limits

A conservative derivative envelope must make the horizontal map a contraction on
an admitted tangent disk. A posterior residual/error disk must fit inside it.
This supports one local root under the numerical model. It does not prove global
uniqueness or certify real-world fluid dynamics. In particular, the amplitude
0.02, choppiness 1 fixture fails the conservative contraction check. That rejection
is not evidence that every point in the sea is folded. The same height spectrum
with choppiness 0.3 passes the envelope admission fixture.

Error propagation converts component envelopes to vector/operator bounds and
includes chart blending, normal projection, conditioning, surface curvature and
velocity gradients. Float64 CPU estimates assume basic arithmetic and at most
four ulps of trigonometric error. Native estimates use the
[WGSL floating-point rules](https://www.w3.org/TR/WGSL/#floating-point-accuracy)
with spatial angles constrained to the stated bounded domain. Neither is a formal
verification of all hardware/library implementations. Accuracy may be unavailable
for rough states or policies tighter than the portable estimates.

Reported memory is logical payload. Physical residency and allocator overhead are
not measured here. The sweep is a correctness check, not a sustained frame-rate
benchmark. No ocean visual acceptance is inferred. Android Vulkan, iOS Metal and
Windows DX12 query qualification remain unrun.

## Commands

```sh
env RUN_NATIVE_GPU=1 /Users/rexraphael/fvm/versions/3.47.5/bin/dart test packages/zyren_geospatial_ocean/test/queries --concurrency=1
/Users/rexraphael/fvm/versions/3.47.5/bin/dart analyze packages/zyren_geospatial_ocean
/Users/rexraphael/fvm/versions/3.47.5/bin/dart run tool/check_package_boundaries.dart
```
