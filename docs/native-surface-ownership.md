# Native surface ownership

You can reserve surface metadata through `gpu3d_native/surfaces.dart`. A reserved
surface stays in `creating` until a platform adapter attaches its GPU output.
Reservation does not advertise shared-texture support. The examples still use
explicit readback while native presentation is being implemented.

The v2 C header is `packages/gpu3d_native/native/include/gpu3d.h`. You can regenerate
its Dart bindings by running `dart run ffigen --config ffigen.yaml` from
`packages/gpu3d_native`. Existing renderer symbols keep their v1 behavior.

## Identity and epochs

Each surface key contains a runtime token, registry slot and generation. These
are identities, never native pointers. Reusing a closed slot increments its
generation, and resizing or suspending a surface advances its epoch. An old
completion can retire its resources but cannot publish into a newer epoch.

Both the Flutter plugin and Dart FFI must load the same Rust library instance.
`SurfaceSession` compares their runtime tokens before registration. The packaged
Apple debug integration verifies this before texture registration. The plugin
uses RTLD_NOLOAD and checks the token from the already loaded gpu3d_runtime
library. It does not load a second native registry. The Rust library name differs
from the flutter_gpu3d CocoaPods module to avoid a framework-name collision.
Release runtime identity remains a qualification check.

## Buffer lifetime

The lease ledger has two independent completion conditions: the producer GPU
has finished, and the native consumer has released the frame. A retired slot
can be reused only after both conditions hold. Dart frame receipts cannot release
a native consumer lease.

Surface sessions allow two or three buffers and at most two submitted producers.
The default is three buffers with one producer. Queued requests share one slot;
a newer request replaces the pending frame. The budget must fit the displayed
frame and a replacement, or creation fails before allocating GPU resources.
Adapters charge actual allocation bytes, including row and page alignment, and
must destroy retired storage before reporting its lease reusable.

Resize keeps old allocations charged until their owners release them. If those
allocations consume the budget, new work returns backpressure. Publication and
notification must happen only after producer completion.

## Cancellation and failure

The Flutter session serializes resize and suspension. If you close it while
creation is pending, it closes the late native attachment once and never exposes
the texture. A failed mutation stops subsequent work until disposal; recovery
creates a new session.

A native timeout stops publication, clears pending work and records `timedOut`.
It does not fabricate GPU completion. Outstanding leases keep the registry slot
alive until actual producer and consumer callbacks arrive. Platform adapters
must report the failure and retain ownership that cannot yet be released safely.
The renderer waits up to two seconds for a submission. A timeout makes the
renderer reject further work and keeps its imported texture owned. Readback
uses the same bounded GPU wait and allows one additional second for its mapping
callback. A failed renderer transfers its complete GPU ownership to a retirement
thread so disposal can return while the driver is still busy. Its device permit
remains charged until native destruction finishes. The process admits at most
32 active or retiring devices; exhausted capacity rejects new renderers. If a
retirement thread cannot start, ownership stays retained and charged until
process exit.

On Metal, fence completion alone does not prove successful execution. The
[pinned HAL patch](../packages/gpu3d_native/native/vendor/README.md) exposes the
submitted command buffers. Every buffer must report successful completion before
the renderer returns success. The GPU timeout test disposes the renderer while
the queue is still blocked, then verifies retirement drains after the gate opens.

## Verification

The ownership suite covers both completion orders, duplicate and stale callbacks,
out-of-order frames, resize with retained consumers, aligned allocation budgets,
timeouts and 10,000 coalesced requests. C ABI tests reject version/runtime/epoch
mismatches and keep request errors separate. Dart calls the generated bindings
against the built library. Flutter tests cover creation, close, resize storms,
suspension and failed mutations through an injected platform boundary.

These checks establish the ownership machinery. They do not qualify a native
presentation adapter or physical-device behavior.

## Experimental Apple bridge

The bridge uses fresh IOSurfaces with at most three live allocations per surface.
Each allocation is charged at its actual aligned size and retains a native lease
until its final native owner releases it. The Rust producer test cycles twenty
frames, holds a consumer through backpressure, and closes only after release.
Flutter's Core Video cache keeps the allocations alive longer. The macOS fixture
records the resulting stall and three retained buffers after unregister, so this
adapter is disabled by default. Read the [checkpoint](apple-presentation-checkpoint.md)
before enabling the experimental constructor option.

A submission rejected before scene preparation leaves geometry residency alone.
If a frame finishes GPU work after its epoch was revoked, status
`FG2_FRAME_SUPERSEDED` tells Dart that scene changes were applied even though
publication was cancelled. This preserves upload/eviction state across retries
without resending immutable geometry IDs. The native race regression submits
1,000 meshes and revokes the epoch while its allocation is live, then restores
an evicted geometry successfully.

After changing the canonical C header, regenerate Dart bindings as above and
run `dart tool/sync_apple_header.dart` from the workspace root. The package
boundary check rejects a stale Apple header copy.
