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
Apple adapter must still prove this in debug and release builds; the current
FFI test verifies the generated records against Rust without a platform plugin.

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
must enforce a bounded wait, report the failure, and retain ownership that cannot
yet be released safely. The current v1 readback renderer's wait has not changed
in this checkpoint.

## Verification

The ownership suite covers both completion orders, duplicate and stale callbacks,
out-of-order frames, resize with retained consumers, aligned allocation budgets,
timeouts and 10,000 coalesced requests. C ABI tests reject version/runtime/epoch
mismatches and keep request errors separate. Dart calls the generated bindings
against the built library. Flutter tests cover creation, close, resize storms,
suspension and failed mutations through an injected platform boundary.

These checks establish the ownership machinery. They do not qualify a native
presentation adapter or physical-device behavior.
