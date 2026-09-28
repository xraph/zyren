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

Use one plugin instance per view. Resizing creates textures in a child resource
scope and compiles a replacement graph before selecting it. Failed candidates
release their allocations and preserve the previous graph. A failed resized
frame reports the error to the caller; it does not stretch the old output.
Closing the attachment releases its resources and clears composition ownership.
You can reattach the instance after disposal to rebuild on another device.

A dependent plugin declares `EffectsPlugin.pluginId` in `dependencies` and reads
`context.service(effectsControls)`. The typed service exposes options and state,
including the compiled size and successful graph-build count.

Missing capabilities reject attachment by default. Set
`unsupported: UnsupportedEffects.bypass` to leave the scene rendering normally
on an adapter without effects. Inspect `state.missingFeatures` to explain that
choice in your UI. Bypass never silently changes the renderer backend.

This example owns final composition for its view. Multiple effects providers
need to cooperate through a shared builder; automatic cross-plugin pass
registration is not implemented yet. There is no temporal history sampling in
these effects. The library depends only on `gpu3d`. Its GPU tests use the native
backend as a development dependency. The separate `example` CLI host declares
the native backend as a runtime dependency so `dart build cli` bundles its native
asset for deployment.
