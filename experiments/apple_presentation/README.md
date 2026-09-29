# Apple texture lifetime probe

Run this on a Mac with Xcode and a Metal device:

```sh
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
  -framework Foundation -framework CoreVideo -framework Metal -framework IOSurface \
  experiments/apple_presentation/iosurface_lifetime.mm \
  -o /tmp/zyren-iosurface-lifetime
/tmp/zyren-iosurface-lifetime
```

The executable checks three ownership assumptions. A one-buffer Core Video pool
recycles its IOSurface after the pixel buffer and CVMetalTexture wrapper are
released, even while another owner holds the MTLTexture. You cannot use pool
availability alone to establish that Flutter has finished sampling a frame.

The second check allocates a fresh IOSurface-backed pixel buffer and attaches
an Objective-C lifetime guard to its IOSurface. A Metal command clears the texture
after waiting on an unsignaled shared event. The probe releases every CPU-side
buffer, wrapper and texture reference, then verifies that the guard survives.
An independent timer signals the event after two seconds. The guard must release
once after GPU completion, within a bounded wait.

Both checks passed on Apple M3 Max with Xcode 27. This is an ownership experiment.
It does not register a Flutter texture, exercise the Rust renderer, measure frame
rate or qualify iOS. A production adapter still needs bounded allocation, real
Flutter retention tests, packaged runtime identity and composition checks.

## Why this matches the importer

The pinned Flutter engine is
`af7e796e161ae0bb1ff0758c71a7105418bd9ded`. Its
[Apple external texture importer](https://github.com/flutter/flutter/blob/af7e796e161ae0bb1ff0758c71a7105418bd9ded/engine/src/flutter/shell/platform/darwin/graphics/FlutterDarwinExternalTextureMetal.mm)
releases the CVMetalTexture wrapper after obtaining the MTLTexture. The
[Impeller Metal command buffer](https://github.com/flutter/flutter/blob/af7e796e161ae0bb1ff0758c71a7105418bd9ded/engine/src/flutter/impeller/renderer/backend/metal/command_buffer_mtl.mm)
uses Metal command buffers with retained resource references. Recheck both paths
when changing Flutter, and verify the actual compositor before enabling an adapter.

The current candidate uses fresh buffers with native lease limits. Pooling may
be added only after consumer completion is proven independently of pool reuse.
This can cost one allocation per presented frame; measurements must include it.

## Cache retention

The additional probe imports three fresh buffers through a Core Video texture
cache and releases their wrappers. All three IOSurfaces remain owned after two
seconds of idle time; an explicit cache flush releases them. Flutter owns its
cache, so the plugin cannot perform that flush through its public texture API.
The packaged Flutter fixture now reproduces the resulting bounded-allocation
stall and macOS teardown retention. See the
[Apple checkpoint](../../docs/apple-presentation-checkpoint.md).
