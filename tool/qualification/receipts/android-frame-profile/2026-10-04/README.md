# Android frame profile transport

You can inspect the decoder and presenter checks in `receipt.json`. All 16
checks passed. The presenter tests cover attached profiles, older plugin replies,
stale frame IDs and a diagnostic failure after native rendering accepted the
scene. The retry must reuse that geometry without uploading it again.

The graph response is bounded to 256 KiB and keeps the existing typed errors.
Both presenter paths preserve unavailable GPU timings as null. Attached profiles
avoid a second platform-channel request after the render reply.

The retained tests use mocked Android transport. See the separate GameLab
receipts for compiled Android and physical-device results; these checks do not
establish frame timing or sustained capacity.
