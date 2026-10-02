# zyren_splats

Render anisotropic Gaussians into a native offscreen image. You provide source
means, positive-definite 3D covariances, linear RGB and opacity. This first slice
uses an orthographic camera, CPU covariance projection and stable depth sorting.

```dart
final renderer = await GaussianSplatRenderer.create(owner, data);
scene.add(renderer.object); // Supplies parent transforms and runtime identity.
final image = await renderer.render(
  camera: OrthographicCamera(),
  size: PhysicalSize(512, 512),
);
await renderer.close();
```

The explicit `render` call produces linear, premultiplied RGBA8 pixels. Adding
the object to a scene does not render splats in that scene's normal frame. The
public procedural graph currently has color attachments only, so this package
does not composite with or depth-test the scene's other objects.

Each Gaussian retains `(sourceUri, sourceVersion, recordIndex)` through sorting.
Its projected covariance is `A C Aᵀ`, where `A` includes the object transform,
orthographic camera axes and viewport scale. The shader evaluates Gaussian
opacity per fragment, truncates at three standard deviations and blends far to
near with premultiplied alpha. These are covariance-based Gaussians, not point
markers. Sorting by mean depth is approximate when Gaussian volumes intersect.

You get a bounded first implementation. The default cap is 32,768 splats, 2 MiB
of projected upload data and 16 MiB of target pixels. Each call creates and retires
its frame resources, including failures; overlapping calls are rejected and close
waits for an accepted frame. Source objects, CPU sorting and readback have separate
host-memory costs. Parent scope closure also invalidates the renderer.

Perspective projection, spherical harmonics, format import, scene-depth integration,
spatial streaming, GPU sorting and mobile qualification remain open. Clipping uses
Gaussian centers at the near/far planes. There is no antialias filter or precise
surface picking. A Gaussian mean or opacity estimate must not be used as a measured
surface point.

```sh
fvm flutter test --no-pub packages/zyren_splats/test/gaussian_test.dart
RUN_NATIVE_GPU=1 fvm dart test packages/zyren_splats/test/native_test.dart
```

On 2026-10-02, Metal pixels for anisotropic falloff and overlapping red/blue
Gaussians matched the analytic expectations within 2/255. Frame resources and
cached pipelines retired to zero. Other native backends and interactive viewport
presentation remain unverified.

You can expose source appearance queries through the shared agent registry:

```dart
final provider = GaussianAgentProvider.forRenderer(
  renderer, view: viewportProvider, instanceId: 'scan',
);
provider.register(registry, onClose: renderer.onClose);
```

Import `package:zyren_splats/agents.dart` for this optional entry point. The host
supplies the shared viewport provider and registry. `inspect` reports source and
residency state; `estimate` returns up to 32 source records with estimated opacity
at viewport-local logical pixels. It handles DPR and reports frame correlation
through the shared viewport context. Perspective estimates return unsupported.

Estimates describe the Gaussian source, even when no matching frame has been
presented. Scene occlusion and section clipping remain unknown. No mutating tools
are registered. Direct registry queries have CPU and Metal offscreen checks;
live MCP, host command integration and geospatial/3D Tiles enrichment remain open.
Run `fvm dart run packages/zyren_splats/example/native.dart` for a native image of
two rotated Gaussians. It writes `gaussians.ppm` as linear RGB on black.
