# Effects plugin

Add this package to a Flutter or headless Dart view before its first attachment:

```dart
final effects = controller.use(EffectsPlugin(
  options: EffectsOptions(exposure: .25, saturation: .8, vignette: .5),
));
effects.options = effects.options.copyWith(saturation: 0);
```

Apply a custom material to one of your meshes with the same public API:

```dart
final pattern = controller.use(PatternMaterialPlugin(mesh, frequency: 8));
pattern.frequency = 3;
```

The pattern uses UV0, so supply geometry with that attribute. It borrows the mesh
and restores its previous material on detach unless you assigned another material
in the meantime. Frequency ranges from 1 to 16 and updates a uniform. Each
attachment compiles its own device-bound program; use a separate mesh when
rendering through independent devices. Unsupported adapters reject by default,
or preserve the original material with `UnsupportedEffects.bypass`.

Exposure uses stops between -2 and 2. Saturation ranges from 0 to 2, vignette from
0 to 1. Values must be finite. Updates invalidate the view and upload a 16-byte
uniform on the next frame; they do not rebuild shader pipelines. The two passes
work in linear light, preserve alpha and clamp color into the RGBA8 range.

Use one plugin instance per view. The plugin registers its color and vignette
passes through `context.graph.addEffect`. The engine owns resize and combines
these passes with contributions from other plugins. Failed candidates
release their allocations and preserve the previous graph. A failed resized
frame reports the error to the caller; it does not stretch the old output.
Closing the attachment releases its resources and removes its contribution.
You can reattach the instance after disposal to rebuild on another device.

A dependent plugin declares `EffectsPlugin.pluginId` in `dependencies` and reads
`context.service(effectsControls)`. The typed service exposes options and state,
including the compiled size and successful graph-build count.

Missing capabilities reject attachment by default. Set
`unsupported: UnsupportedEffects.bypass` to leave the scene rendering normally
on an adapter without effects. Inspect `state.missingFeatures` to explain that
choice in your UI. Bypass never silently changes the renderer backend.

Your own effect can run after this one with
`after: {EffectsPlugin.pluginId}` on `context.graph.addEffect`. That is an effect
ordering constraint, separate from the plugin dependency needed to read the typed
controls service. Disabling these effects lets the next effect read scene color.
The library depends only on `gpu3d`. Its GPU tests use the native
backend as a development dependency. The separate `example` CLI host declares
the native backend as a runtime dependency so `dart build cli` bundles its native
asset for deployment.

You can add frame blending after the spatial effects:

```dart
final temporal = controller.use(TemporalBlendPlugin(
  enabled: true,
  retention: .8,
  after: {EffectsPlugin.pluginId},
));
temporal.reset();
```

Retention is the previous-frame weight, finite and between zero inclusive and
one exclusive. The default is .8, but the plugin starts disabled unless you pass
`enabled: true`. Changing retention updates a uniform without recompiling.
The effect requests continuous frames while enabled and blends alpha-weighted
linear color using engine-owned history. It provides no motion or depth rejection,
so moving objects leave trails. This is a history API example, not TAA.

Call `temporal.reset()` or `controller.invalidateHistory()` after a camera jump.
Resize, projection changes, camera replacement and graph rebuilds reset samples
automatically. `temporal.historyFrames` reports the shared graph's successful
frame count since reset. Unsupported adapters reject by default; explicit
`UnsupportedEffects.bypass` keeps normal scene rendering.
